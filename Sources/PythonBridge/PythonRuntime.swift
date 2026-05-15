import Foundation

/// Owns the embedded Python interpreter lifecycle.
///
/// BeeWare's `install_python` build script lays out the app bundle like:
///   <bundle>/python/lib/python3.13/   — full stdlib (PYTHONHOME)
///   <bundle>/app/                       — our Python application code (sys.path[0])
///   <bundle>/app_packages/              — installed wheels (site-packages)
///   <bundle>/Frameworks/*.framework     — per-`.so` frameworks created at build time
///
/// Init sequence mirrors BeeWare's testbed (isolated config, PYTHONHOME, signal
/// handlers, site.addsitedir for app_packages, sys.path[0] = app). Must be called
/// exactly once before any other Python operation.
///
/// After init, the calling thread releases the GIL via `PyEval_SaveThread()` so
/// RNS / LXMF background threads can run. All subsequent Python work must be
/// wrapped in `withGIL { ... }` which acquires and releases the GIL for the
/// duration of the closure — works from any thread.
final class PythonRuntime {
    static let shared = PythonRuntime()

    enum State { case uninitialized, running, failed(String), finalized }
    private(set) var state: State = .uninitialized

    /// Returned by `PyEval_SaveThread()` after init; the embed thread's saved state.
    /// We don't actually re-use this — `PyGILState_Ensure/Release` is reentrant
    /// and works from any thread — but we keep it alive so `Py_Finalize` can find
    /// it if we ever shut down cleanly.
    private var savedThreadState: OpaquePointer?

    private init() {}

    /// Initialize Python. Returns `sys.version` on success.
    @discardableResult
    func start() -> Result<String, Error> {
        guard case .uninitialized = state else {
            return .failure(RuntimeError.alreadyStarted)
        }

        let bundlePath = Bundle.main.resourcePath ?? Bundle.main.bundlePath
        let pythonHome = "\(bundlePath)/python"
        let appPath = "\(bundlePath)/app"
        let appPackagesPath = "\(bundlePath)/app_packages"

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
            pyStatus = ColumbaPy_PyConfig_SetHome(&config, homeWide)
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

        if !addSiteDir(appPackagesPath) {
            return failed("Failed to add app_packages site dir at \(appPackagesPath)")
        }
        if !prependSysPath(appPath) {
            return failed("Failed to prepend \(appPath) to sys.path")
        }
        FileManager.default.changeCurrentDirectoryPath(appPath)

        guard let version = readSysVersion() else {
            return failed("Could not read sys.version after init")
        }

        // Release the GIL so RNS / LXMF threads can run when started later.
        // PyGILState_Ensure/Release will re-acquire it from any thread for each call.
        savedThreadState = OpaquePointer(PyEval_SaveThread())

        state = .running
        return .success(version)
    }

    /// Run a block while holding the Python GIL. Safe to call from any thread.
    /// Nested calls are fine — PyGILState_Ensure/Release is reentrant.
    func withGIL<T>(_ body: () throws -> T) rethrows -> T {
        let gilState = PyGILState_Ensure()
        defer { PyGILState_Release(gilState) }
        return try body()
    }

    private func addSiteDir(_ path: String) -> Bool {
        guard let siteModule = PyImport_ImportModule("site") else { return false }
        defer { Py_DecRef(siteModule) }
        guard let addsitedir = PyObject_GetAttrString(siteModule, "addsitedir") else { return false }
        defer { Py_DecRef(addsitedir) }
        guard PyCallable_Check(addsitedir) != 0 else { return false }
        guard let pathObj = PyUnicode_FromString(path) else { return false }
        guard let result = PyObject_CallOneArg(addsitedir, pathObj) else {
            Py_DecRef(pathObj)
            return false
        }
        Py_DecRef(pathObj)
        Py_DecRef(result)
        return true
    }

    private func prependSysPath(_ path: String) -> Bool {
        guard let sysModule = PyImport_ImportModule("sys") else { return false }
        defer { Py_DecRef(sysModule) }
        guard let sysPath = PyObject_GetAttrString(sysModule, "path") else { return false }
        defer { Py_DecRef(sysPath) }
        guard let pathObj = PyUnicode_FromString(path) else { return false }
        let result = PyList_Insert(sysPath, 0, pathObj)
        Py_DecRef(pathObj)
        return result == 0
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
        return .failure(RuntimeError.initFailed(reason))
    }

    enum RuntimeError: LocalizedError {
        case alreadyStarted
        case initFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyStarted: return "Python runtime already started"
            case .initFailed(let reason): return "Python init failed: \(reason)"
            }
        }
    }
}
