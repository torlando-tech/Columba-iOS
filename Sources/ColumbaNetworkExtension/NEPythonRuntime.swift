//
//  NEPythonRuntime.swift
//  ColumbaNetworkExtension
//
//  Embedded CPython interpreter lifecycle for the NE process.
//
//  This is the FOUNDATION for running the real Python RNS runtime in the NE
//  (moving the entire Reticulum runtime out of the app into the extension).
//  It mirrors the app's Sources/PythonBridge/PythonRuntime.swift but:
//    • targets the NE (Bundle.main = the appex, resourcePath = appex root),
//    • logs through ExtensionDiagLog (the NE's PII-free channel), never NSLog,
//    • is deliberately minimal in this first slice: it proves the CPython C
//      API initializes in the NE sandbox, by reading sys.version back.
//
//  The Python framework is embedded in the appex (Frameworks/Python.framework)
//  and resolves at runtime via the appex's @executable_path/Frameworks rpath
//  (the framework's install name is @rpath/Python.framework/Python). The
//  standard library is installed into <appex>/python by the "Install Python
//  stdlib (NE)" build phase; PYTHONHOME = <appex>/python.
//
//  After init, the calling thread releases the GIL via PyEval_SaveThread() so
//  RNS/LXMF background threads can run; all later Python work wraps in
//  withGIL { } (PyGILState_Ensure/Release is reentrant, safe from any thread).
//
//  COLLISION RULE (hard): this file imports ONLY Foundation + the CPython C API
//  (via the NE bridging header). It must NOT import RNSAPI / ReticulumSwift /
//  LXMFSwift. The RNS engine that will use this interpreter lives behind the
//  NodeEngine seam as a sibling conformance, not in this file.
//

import Foundation

/// Owns the embedded Python interpreter in the NE process.
final class NEPythonRuntime: @unchecked Sendable {
    static let shared = NEPythonRuntime()

    enum State: Equatable { case uninitialized, running, failed(String), finalized }
    private(set) var state: State = .uninitialized

    /// The embed thread's saved state from PyEval_SaveThread(). Kept alive so
    /// Py_Finalize can find it; PyGILState_Ensure/Release re-acquires from any
    /// thread regardless, so it is not reused directly.
    private var savedThreadState: OpaquePointer?

    private init() {}

    /// Initialize CPython. Returns sys.version on success. Must be called exactly
    /// once before any other Python operation.
    @discardableResult
    func start() -> Result<String, Error> {
        guard state == .uninitialized else {
            return .failure(NEError.alreadyStarted)
        }
        ExtensionDiagLog.log("[NE-PY] init begin")

        let resourcePath = Bundle.main.resourcePath ?? Bundle.main.bundlePath
        let pythonHome = "\(resourcePath)/python"

        setenv("NO_COLOR", "1", 1)
        setenv("PYTHON_COLORS", "0", 1)

        var preconfig = PyPreConfig()
        PyPreConfig_InitIsolatedConfig(&preconfig)
        preconfig.utf8_mode = 1

        var pyStatus = Py_PreInitialize(&preconfig)
        if PyStatus_Exception(pyStatus) != 0 {
            return failed("Py_PreInitialize: \(message(pyStatus))")
        }

        var config = PyConfig()
        PyConfig_InitIsolatedConfig(&config)
        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.install_signal_handlers = 1

        if let homeWide = Py_DecodeLocale(pythonHome, nil) {
            pyStatus = ColumbaNEPy_PyConfig_SetHome(&config, homeWide)
            PyMem_RawFree(homeWide)
            if PyStatus_Exception(pyStatus) != 0 {
                PyConfig_Clear(&config)
                return failed("PyConfig_SetString(home): \(message(pyStatus))")
            }
        }

        pyStatus = PyConfig_Read(&config)
        if PyStatus_Exception(pyStatus) != 0 {
            PyConfig_Clear(&config)
            return failed("PyConfig_Read: \(message(pyStatus))")
        }

        pyStatus = Py_InitializeFromConfig(&config)
        PyConfig_Clear(&config)
        if PyStatus_Exception(pyStatus) != 0 {
            return failed("Py_InitializeFromConfig: \(message(pyStatus))")
        }

        if !addSiteDir("app_packages") {
            return failed("failed to add app_packages site dir (\(resourcePath)/app_packages)")
        }
        if !prependSysPath("app") {
            return failed("failed to prepend app dir to sys.path (\(resourcePath)/app)")
        }

        guard let version = readSysVersion() else {
            return failed("could not read sys.version after init (stdlib missing at \(pythonHome)?)")
        }

        // Release the GIL so RNS/LXMF threads can run when started later.
        savedThreadState = OpaquePointer(PyEval_SaveThread())

        state = .running
        ExtensionDiagLog.log("[NE-PY] init OK sys.version=\(version)")
        return .success(version)
    }

    /// Prove the real Python RNS runtime loads + runs in the NE. This is the
    /// de-risk probe for the in-NE RNS port: it mirrors the app's rns_bridge
    /// startup (the platform.system() -> "Darwin" patch, `import RNS/LXMF`,
    /// `import rns_bridge`) and then constructs a live RNS.Node so the RNS
    /// daemon threads actually run in the NE process. The constructed node is
    /// kept in `__main__._ne_node` for later driving (the NodeEngine slice).
    ///
    /// Runs on the GIL. Returns a short human-readable status string that the
    /// caller logs to ext-diag.log. Never throws the NE down: a probe failure
    /// is a logged result, not a crash.
    func probeRNS() -> String {
        let probe = """
        import io, sys, traceback
        _buf = io.StringIO(); _old = sys.stdout; sys.stdout = _buf
        try:
            import platform as _p
            _rs = _p.system
            _p.system = lambda *a, **k: "Darwin" if _rs(*a, **k) == "iOS" else _rs(*a, **k)
            import RNS, LXMF
            import rns_bridge
            out = ["RNS=%s" % getattr(RNS, "__version__", "?"),
                   "LXMF=%s" % getattr(LXMF, "__version__", "?")]
            _node = RNS.Node(hash=bytes.fromhex("0123456789abcdef0123456789abcdef0123"))
            import __main__
            __main__._ne_node = _node
            out.append("node=constructed")
        except Exception:
            traceback.print_exc(file=_buf)
            out = ["PROBE_FAILED"]
        sys.stdout = _old
        import __main__
        __main__._probe_result = _buf.getvalue()
        """
        withGIL {
            PyRun_SimpleString(probe)
        }
        let result = readMainAttr("_probe_result") ?? "(no probe result)"
        return result
    }

    /// After the probe constructs the node, let the RNS daemon threads run
    /// (GIL released during the delay) and then report whether the node is
    /// actually running. Strong proof the runtime is live in the NE.
    func probeNodeRunning() -> String {
        Thread.sleep(forTimeInterval: 2.0)   // GIL is released at this point
        let check = """
        import __main__
        _n = getattr(__main__, "_ne_node", None)
        _r = "node=None" if _n is None else ("node=running" if _n.isRunning() else "node=stopped")
        __main__._probe_result = _r
        """
        withGIL {
            PyRun_SimpleString(check)
        }
        return readMainAttr("_probe_result") ?? "(no node status)"
    }

    private func readMainAttr(_ name: String) -> String? {
        guard let mainModule = PyImport_ImportModule("__main__") else { return nil }
        defer { Py_DecRef(mainModule) }
        guard let val = PyObject_GetAttrString(mainModule, name) else { return nil }
        defer { Py_DecRef(val) }
        guard let cstr = PyUnicode_AsUTF8(val) else { return nil }
        return String(cString: cstr)
    }

    private func addSiteDir(_ relPath: String) -> Bool {
        let resourcePath = Bundle.main.resourcePath ?? Bundle.main.bundlePath
        let siteDir = "\(resourcePath)/\(relPath)"
        guard let siteModule = PyImport_ImportModule("site") else { return false }
        defer { Py_DecRef(siteModule) }
        guard let addsitedir = PyObject_GetAttrString(siteModule, "addsitedir") else { return false }
        defer { Py_DecRef(addsitedir) }
        guard PyCallable_Check(addsitedir) != 0 else { return false }
        guard let pathObj = PyUnicode_FromString(siteDir) else { return false }
        guard let result = PyObject_CallOneArg(addsitedir, pathObj) else {
            Py_DecRef(pathObj)
            return false
        }
        Py_DecRef(pathObj)
        Py_DecRef(result)
        return true
    }

    private func prependSysPath(_ relPath: String) -> Bool {
        let resourcePath = Bundle.main.resourcePath ?? Bundle.main.bundlePath
        let appDir = "\(resourcePath)/\(relPath)"
        guard let sysModule = PyImport_ImportModule("sys") else { return false }
        defer { Py_DecRef(sysModule) }
        guard let sysPath = PyObject_GetAttrString(sysModule, "path") else { return false }
        defer { Py_DecRef(sysPath) }
        guard let pathObj = PyUnicode_FromString(appDir) else { return false }
        let result = PyList_Insert(sysPath, 0, pathObj)
        Py_DecRef(pathObj)
        return result == 0
    }

    /// Run a block while holding the Python GIL. Safe from any thread; nested
    /// calls are fine (PyGILState_Ensure/Release is reentrant).
    func withGIL<T>(_ body: () throws -> T) rethrows -> T {
        let gilState = PyGILState_Ensure()
        defer { PyGILState_Release(gilState) }
        return try body()
    }

    private func readSysVersion() -> String? {
        guard let sysModule = PyImport_ImportModule("sys") else {
            PyErr_Print()
            return nil
        }
        defer { Py_DecRef(sysModule) }
        guard let versionObj = PyObject_GetAttrString(sysModule, "version") else {
            PyErr_Print()
            return nil
        }
        defer { Py_DecRef(versionObj) }
        guard let cstr = PyUnicode_AsUTF8(versionObj) else { return nil }
        return String(cString: cstr)
    }

    private func message(_ status: PyStatus) -> String {
        if let cstr = status.err_msg { return String(cString: cstr) }
        return "(no message)"
    }

    private func failed(_ reason: String) -> Result<String, Error> {
        state = .failed(reason)
        ExtensionDiagLog.log("[NE-PY] init FAILED \(reason)")
        return .failure(NEError.initFailed(reason))
    }

    enum NEError: LocalizedError {
        case alreadyStarted
        case initFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyStarted: return "NE Python runtime already started"
            case .initFailed(let reason): return "NE Python init failed: \(reason)"
            }
        }
    }
}
