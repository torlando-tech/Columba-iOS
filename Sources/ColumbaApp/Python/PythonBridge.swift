import Foundation

/// Wraps the Python `rns_bridge` module. Every call hops onto a dedicated serial
/// queue (so all Python work is serialized — RNS internally still runs its own
/// background threads, but our Swift-initiated calls don't race) and uses
/// `PythonRuntime.shared.withGIL` to hold the GIL for the duration.
///
/// Events from RNS / LXMF callbacks land on a thread-safe Python queue.Queue;
/// Swift drains it via a Combine `Timer.publish` at ~5 Hz.
final class PythonBridge: @unchecked Sendable {
    // Connection / send results bubble up as plain enums; the SwiftUI layer
    // turns them into user-facing strings.
    struct LocalInfo: Equatable {
        let identityHash: String
        let destinationHash: String
    }

    enum BridgeError: LocalizedError {
        case notStarted
        case pythonException(String)
        case marshallingFailure(String)

        var errorDescription: String? {
            switch self {
            case .notStarted: return "Python bridge not started"
            case .pythonException(let m): return "Python error: \(m)"
            case .marshallingFailure(let m): return "Marshalling: \(m)"
            }
        }
    }

    enum SendOutcome: Equatable {
        case queued
        case requestingPath
        case badHash
        case notStarted
        case other(String)
    }

    enum Event: Equatable {
        case announce(destHash: String, displayName: String, t: Date)
        case inbound(sourceHash: String, content: String, title: String, t: Date)
        case state(String, t: Date)
    }

    private let queue = DispatchQueue(label: "network.columba.python", qos: .userInitiated)
    private var module: UnsafeMutablePointer<PyObject>?

    init() {}

    // MARK: - Public API

    /// Initialize Reticulum + LXMRouter inside Python. Returns local hashes on success.
    ///
    /// `identityBytes` is the preferred path for production iOS — Swift reads the
    /// 64-byte identity blob from Keychain and hands it over here; Python loads it
    /// via `RNS.Identity.from_bytes()`, never touching the filesystem for keys.
    /// Pass `nil` to fall back to `identityPath` (file-on-disk; mainly for CLI / PoC).
    func start(
        configDir: String,
        identityPath: String,
        tcpHost: String,
        tcpPort: Int,
        displayName: String,
        identityBytes: Data? = nil
    ) async throws -> LocalInfo {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                try ensureModuleLoaded()
                guard let module = self.module else { throw BridgeError.notStarted }
                guard let fn = PyObject_GetAttrString(module, "start") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }

                // Positional args 0..4, then identity_bytes (None or bytes) at slot 5.
                let args = PyTuple_New(6)
                guard args != nil else { throw BridgeError.marshallingFailure("PyTuple_New") }
                defer { Py_DecRef(args) }

                let strings = [configDir, identityPath, tcpHost]
                for (idx, value) in strings.enumerated() {
                    guard let u = PyUnicode_FromString(value) else {
                        throw BridgeError.marshallingFailure("PyUnicode_FromString[\(idx)]")
                    }
                    PyTuple_SetItem(args, idx, u) // steals ref
                }
                guard let portObj = PyLong_FromLongLong(Int64(tcpPort)) else {
                    throw BridgeError.marshallingFailure("PyLong_FromLongLong")
                }
                PyTuple_SetItem(args, 3, portObj)
                guard let nameObj = PyUnicode_FromString(displayName) else {
                    throw BridgeError.marshallingFailure("PyUnicode_FromString(name)")
                }
                PyTuple_SetItem(args, 4, nameObj)

                // identity_bytes at slot 5: either Py_None or a bytes object.
                if let data = identityBytes, !data.isEmpty {
                    let bytesObj: UnsafeMutablePointer<PyObject>? = data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return nil }
                        return PyBytes_FromStringAndSize(base.assumingMemoryBound(to: CChar.self), raw.count)
                    }
                    guard let bytesObj else { throw BridgeError.marshallingFailure("PyBytes_FromStringAndSize") }
                    PyTuple_SetItem(args, 5, bytesObj) // steals ref
                } else {
                    PyTuple_SetItem(args, 5, ColumbaPy_None()) // steals ref
                }

                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                return try extractLocalInfo(result)
            }
        }
    }

    func stop() async throws {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return }
                guard let fn = PyObject_GetAttrString(module, "stop") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                guard let args = PyTuple_New(0) else { return }
                defer { Py_DecRef(args) }
                if let r = PyObject_CallObject(fn, args) { Py_DecRef(r) }
            }
        }
    }

    func resetIdentity(identityPath: String) async throws {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                try ensureModuleLoaded()
                guard let module = self.module else { return }
                guard let fn = PyObject_GetAttrString(module, "reset_identity") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                guard let path = PyUnicode_FromString(identityPath) else {
                    throw BridgeError.marshallingFailure("identityPath")
                }
                guard let r = PyObject_CallOneArg(fn, path) else {
                    Py_DecRef(path)
                    throw BridgeError.pythonException(currentPythonException())
                }
                Py_DecRef(path)
                Py_DecRef(r)
            }
        }
    }

    func sendOpportunistic(destHashHex: String, content: String) async throws -> SendOutcome {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return .notStarted }
                guard let fn = PyObject_GetAttrString(module, "send_opportunistic") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                let args = PyTuple_New(2)!
                defer { Py_DecRef(args) }
                PyTuple_SetItem(args, 0, PyUnicode_FromString(destHashHex)!)
                PyTuple_SetItem(args, 1, PyUnicode_FromString(content)!)
                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                let reason = pyStringFromDict(result, key: "reason") ?? "unknown"
                let ok = pyBoolFromDict(result, key: "ok") ?? false
                if ok { return .queued }
                switch reason {
                case "requesting-path": return .requestingPath
                case "bad-hash": return .badHash
                case "not-started": return .notStarted
                default: return .other(reason)
                }
            }
        }
    }

    /// Read RNS Transport diagnostic info — interfaces, online state, table sizes.
    func status() async -> [String: String] {
        await withCheckedContinuation { cont in
            queue.async {
                let out = PythonRuntime.shared.withGIL { () -> [String: String] in
                    guard let module = self.module else { return [:] }
                    guard let fn = PyObject_GetAttrString(module, "status") else { return [:] }
                    defer { Py_DecRef(fn) }
                    guard let args = PyTuple_New(0) else { return [:] }
                    defer { Py_DecRef(args) }
                    guard let result = PyObject_CallObject(fn, args) else { return [:] }
                    defer { Py_DecRef(result) }
                    return self.dictToStringMap(result)
                }
                cont.resume(returning: out)
            }
        }
    }

    private func dictToStringMap(_ d: UnsafeMutablePointer<PyObject>) -> [String: String] {
        guard let repr = PyObject_Str(d) else { return [:] }
        defer { Py_DecRef(repr) }
        guard let c = PyUnicode_AsUTF8(repr) else { return [:] }
        return ["raw": String(cString: c)]
    }

    /// Drain pending events from the Python-side queue.Queue. Returns empty list
    /// if the bridge isn't started yet.
    func drainEvents() async -> [Event] {
        await withCheckedContinuation { cont in
            queue.async {
                let events = PythonRuntime.shared.withGIL { () -> [Event] in
                    guard let module = self.module else { return [] }
                    guard let fn = PyObject_GetAttrString(module, "drain_events") else { return [] }
                    defer { Py_DecRef(fn) }
                    guard let args = PyTuple_New(0) else { return [] }
                    defer { Py_DecRef(args) }
                    guard let result = PyObject_CallObject(fn, args) else { return [] }
                    defer { Py_DecRef(result) }
                    return self.parseEventList(result)
                }
                cont.resume(returning: events)
            }
        }
    }

    // MARK: - Private

    private func runOnQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func ensureModuleLoaded() throws {
        if module != nil { return }
        guard let m = PyImport_ImportModule("rns_bridge") else {
            throw BridgeError.pythonException(currentPythonException())
        }
        module = m
    }

    private func currentPythonException() -> String {
        // Drain the error indicator into a string. Mirrors how PyErr_Print would format.
        guard PyErr_Occurred() != nil else { return "(no error set)" }
        var ptype: UnsafeMutablePointer<PyObject>?
        var pvalue: UnsafeMutablePointer<PyObject>?
        var ptraceback: UnsafeMutablePointer<PyObject>?
        PyErr_Fetch(&ptype, &pvalue, &ptraceback)
        PyErr_NormalizeException(&ptype, &pvalue, &ptraceback)
        defer {
            if let p = ptype { Py_DecRef(p) }
            if let p = pvalue { Py_DecRef(p) }
            if let p = ptraceback { Py_DecRef(p) }
        }
        var description = "Python error"
        if let value = pvalue, let str = PyObject_Str(value) {
            defer { Py_DecRef(str) }
            if let c = PyUnicode_AsUTF8(str) { description = String(cString: c) }
        }
        if let type = ptype, let tname = PyObject_GetAttrString(type, "__name__") {
            defer { Py_DecRef(tname) }
            if let c = PyUnicode_AsUTF8(tname) {
                description = "\(String(cString: c)): \(description)"
            }
        }
        return description
    }

    private func extractLocalInfo(_ d: UnsafeMutablePointer<PyObject>) throws -> LocalInfo {
        guard let identityHash = pyStringFromDict(d, key: "identity_hash"),
              let destinationHash = pyStringFromDict(d, key: "destination_hash") else {
            throw BridgeError.marshallingFailure("LocalInfo dict missing fields")
        }
        return LocalInfo(identityHash: identityHash, destinationHash: destinationHash)
    }

    private func pyStringFromDict(_ d: UnsafeMutablePointer<PyObject>, key: String) -> String? {
        guard let item = PyDict_GetItemString(d, key) else { return nil }
        guard let c = PyUnicode_AsUTF8(item) else { return nil }
        return String(cString: c)
    }

    private func pyBoolFromDict(_ d: UnsafeMutablePointer<PyObject>, key: String) -> Bool? {
        guard let item = PyDict_GetItemString(d, key) else { return nil }
        return PyObject_IsTrue(item) == 1
    }

    private func pyDoubleFromDict(_ d: UnsafeMutablePointer<PyObject>, key: String) -> Double? {
        guard let item = PyDict_GetItemString(d, key) else { return nil }
        let v = PyFloat_AsDouble(item)
        if v == -1.0 && PyErr_Occurred() != nil { PyErr_Clear(); return nil }
        return v
    }

    private func parseEventList(_ list: UnsafeMutablePointer<PyObject>) -> [Event] {
        let count = PyObject_Length(list)
        guard count > 0 else { return [] }
        var out: [Event] = []
        for i in 0..<count {
            guard let item = PyList_GetItem(list, i) else { continue } // borrowed
            guard let kind = pyStringFromDict(item, key: "kind") else { continue }
            let t = pyDoubleFromDict(item, key: "t").map { Date(timeIntervalSince1970: $0) } ?? Date()
            switch kind {
            case "announce":
                let h = pyStringFromDict(item, key: "dest_hash") ?? ""
                let name = pyStringFromDict(item, key: "display_name") ?? ""
                out.append(.announce(destHash: h, displayName: name, t: t))
            case "inbound":
                let h = pyStringFromDict(item, key: "source_hash") ?? ""
                let c = pyStringFromDict(item, key: "content") ?? ""
                let title = pyStringFromDict(item, key: "title") ?? ""
                out.append(.inbound(sourceHash: h, content: c, title: title, t: t))
            case "state":
                let v = pyStringFromDict(item, key: "value") ?? "?"
                out.append(.state(v, t: t))
            default:
                continue
            }
        }
        return out
    }
}
