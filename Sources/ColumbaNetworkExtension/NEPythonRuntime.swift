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

    /// Serializes CPython init so the `startTunnel` Task and the first `.start`
    /// IPC (both of which may call `start()` at boot) can't both observe
    /// `.uninitialized` and double-run `Py_Initialize`.
    private let initLock = NSLock()

    private init() {}

    /// Initialize CPython. Returns sys.version on success. Idempotent: safe to
    /// call from any thread; a concurrent caller blocks until init settles, then
    /// gets the same result (the real interpreter init runs exactly once).
    @discardableResult
    func start() -> Result<String, Error> {
        initLock.lock()
        switch state {
        case .running:
            initLock.unlock()
            return .success("python already running")
        case .failed(let reason):
            initLock.unlock()
            return .failure(NEError.initFailed(reason))
        case .uninitialized:
            break
        case .finalized:
            initLock.unlock()
            return .failure(NEError.alreadyStarted)
        }
        let result = performInit()
        // On failure `performInit` already set state=.failed; on success .running.
        initLock.unlock()
        return result
    }

    private func performInit() -> Result<String, Error> {
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

    /// Prove the real Python RNS runtime loads + runs in the NE, STAGED: each
    /// step runs as its own GIL-holding Python call and logs its result to
    /// ext-diag BEFORE the next. If the process is terminated mid-probe (the
    /// ~7s crash loop), the last logged line names the step that died - e.g.
    /// `import RNS` (loads CRNS/cffi/cryptography) vs `RNS.Node()` (daemon
    /// startup). This is the de-risk probe for the in-NE RNS port.
    ///
    /// The platform.system() -> "Darwin" patch (required before `import RNS` or
    /// netinfo misreads addresses) is applied once at the front and persists for
    /// the interpreter's life.
    func probeRNS() {
        runStage("prep") {
            """
            import platform as _p
            _rs = _p.system
            _p.system = lambda *a, **k: "Darwin" if _rs(*a, **k) == "iOS" else _rs(*a, **k)
            print("ok")
            """
        }
        runStage("importRNS") {
            """
            import RNS, LXMF
            print("RNS=%s LXMF=%s" % (getattr(RNS, "__version__", "?"), getattr(LXMF, "__version__", "?")))
            """
        }
        runStage("importBridge") {
            """
            import rns_bridge
            print("ok")
            """
        }
        // Construct the real RNS runtime, exactly as the app's known-good
        // rns_bridge.py does (RNS.Reticulum(config_dir) - NOT RNS.Node, which
        // does not exist; the earlier AttributeError was my wrong class name,
        // not an RNS problem). tempfile.mkdtemp uses TMPDIR, which iOS sets to
        // a writable per-process tmp dir for extensions; if it fails the
        // runStage wrapper logs the traceback so we can pick another path.
        runStage("nodeConstruct") {
            """
            import os, tempfile
            import RNS
            _d = tempfile.mkdtemp(prefix="rnsne-")
            _ret = RNS.Reticulum(_d)
            import __main__
            __main__._ne_ret = _ret
            print("constructed dir=" + _d)
            """
        }
        // After construction, let the RNS daemon threads run (GIL released
        // during the delay) and report whether the node is actually up.
        Thread.sleep(forTimeInterval: 2.0)
        runStage("nodeRunning") {
            """
            import RNS, __main__
            _r = getattr(__main__, "_ne_ret", None)
            try:
                _ifs = RNS.Transport.interfaces or []
                _n = len(_ifs)
            except Exception as _e:
                _n = "err:" + repr(_e)
            print("reticulum=" + ("up" if _r is not None else "none") + " ifaces=" + str(_n))
            """
        }
    }

    /// Run one Python statement block under the GIL, logging its captured
    /// stdout (or the failure) to ext-diag under the `[NE-PY-RNS] <stage>`
    /// marker. A stage that raises logs the traceback; a stage that is never
    /// logged means the process died DURING it (the previous stage is the last
    /// safe point).
    ///
    /// GIL: the embed thread released the GIL at init (so RNS background threads
    /// can run), so EVERY C-API call here must re-acquire it. The run AND the
    /// result-read happen inside ONE `withGIL` block - reading the result after
    /// releasing the GIL is a hard crash (PyImport_ImportModule on a
    /// non-GIL-holding thread → SIGSEGV in PyUnicode_New), which is exactly the
    /// 0x10 fault we saw in the NE crash logs.
    private func runStage(_ stage: String, _ code: () -> String) {
        // Indent EVERY line of the stage script by 4 so it sits inside the
        // `try:` block. Interpolating the raw multi-line script only indents
        // its first line (a leading newline), so the body lands at column 0 -
        // an IndentationError that makes the whole wrapper fail to compile and
        // _stage_out never get set. That is exactly why every stage reported
        // "(no output)".
        let indented = indentPython(code(), by: 4)
        let wrapper = """
        import io, sys, traceback
        _buf = io.StringIO(); _o = sys.stdout; sys.stdout = _buf
        try:
        \(indented)
        except SystemExit:
            raise
        except BaseException:
            traceback.print_exc(file=_buf)
        sys.stdout = _o
        import __main__
        __main__._stage_out = _buf.getvalue()
        """
        let out = withGIL { () -> String? in
            let rc = PyRun_SimpleString(wrapper)
            if rc < 0 {
                // The wrapper itself failed to compile/run. Read whatever the
                // stage may have emitted (e.g. output before an uncaught
                // error), else report the failure so it is visible in
                // ext-diag instead of a silent "(no output)".
                let captured = readMainAttr("_stage_out")
                if let captured, !captured.isEmpty { return captured }
                return "(wrapper failed rc=\(rc))"
            }
            return readMainAttr("_stage_out")
        }
        ExtensionDiagLog.log("[NE-PY-RNS] \(stage): \(out.map { $0.replacingOccurrences(of: "\n", with: " | ") } ?? "(no output)")")
    }

    /// Prefix every non-empty line of a multi-line Python snippet with `by`
    /// spaces, so it can be embedded under an indented block (e.g. `try:`).
    private func indentPython(_ s: String, by: Int) -> String {
        let pad = String(repeating: " ", count: by)
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
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

    /// Call `rns_bridge.<fn>(...)` and return its result as a JSON string.
    ///
    /// This is the generic seam the in-NE Python RNS engine (`NEPythonRNS`)
    /// uses to drive the live node: it keeps ALL the CPython C-API detail here
    /// (NEPythonRuntime's file) and exposes one plain-string-in / string-out
    /// method so the engine never touches the C API directly.
    ///
    /// `payload` is JSON of the form `{"args":[...], "kwargs":{...}}`. A Python
    /// `bytes` argument is carried as `{"__b64__": "<base64>"}` (JSON can't hold
    /// raw bytes) and decoded back on the Python side; the identity private-key
    /// blob rides this way. `rns_bridge` is imported on first use (its import
    /// applies the `platform.system() -> "Darwin"` patch the NE needs).
    ///
    /// The return is a JSON string, one of:
    ///   `{"ok":true,"result":"<json-string>"}`  - the call's JSON-serializable result
    ///   `{"ok":false,"error":"<traceback>"}`    - the call raised
    /// or `nil` if the wrapper itself failed to compile/run (a Swift-side error).
    ///
    /// GIL: the whole call (run + result-read) is one `withGIL` block. Holding
    /// the GIL across a blocking call (e.g. `start`, which blocks until the node
    /// is up) is correct: RNS's C-level daemon threads run without the GIL, and
    /// the Python-level ones are scheduled when it's released on return.
    func callBridge(_ fn: String, payload: String) -> String? {
        let snippet = callBridgeSnippet(fn: fn, payload: payload)
        return withGIL {
            let rc = PyRun_SimpleString(snippet)
            guard rc == 0 else { return nil }
            return readMainAttr("_call_out")
        }
    }

    /// Build the Python snippet that calls `rns_bridge.<fn>` with the decoded
    /// payload and stores the result in `__main__._call_out`. See `callBridge`.
    private func callBridgeSnippet(fn: String, payload: String) -> String {
        // JSON-encode the fn name + payload as Python string literals so no user
        // value can break out of the snippet (the values ride inside a quoted
        // Python literal parsed by json.loads, not by string interpolation into
        // executable code).
        let fnLit = pyLiteral(fn)
        let payloadLit = pyLiteral(payload)
        return """
        import json, base64, traceback
        import rns_bridge
        import __main__
        def _dec(v):
            if isinstance(v, dict) and set(v) == {'__b64__'}:
                return base64.b64decode(v['__b64__'] or b'')
            if isinstance(v, dict):
                return {k: _dec(x) for k, x in v.items()}
            if isinstance(v, list):
                return [_dec(x) for x in v]
            return v
        _p = _dec(json.loads(\(payloadLit)))
        _fn = \(fnLit)
        try:
            _res = getattr(rns_bridge, _fn)(*(_p.get('args') or []), **(_p.get('kwargs') or {}))
            try:
                _out = json.dumps(_res)
            except TypeError:
                _out = json.dumps({'__repr__': repr(_res)})
            __main__._call_out = json.dumps({'ok': True, 'result': _out})
        except BaseException:
            __main__._call_out = json.dumps({'ok': False, 'error': traceback.format_exc()})
        """
    }

    /// Encode `s` as a single-quoted Python string literal (escaping backslash +
    /// single quote). Used to embed a value as a Python literal rather than
    /// interpolating it into executable code.
    private func pyLiteral(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'")
        return "'" + esc + "'"
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
