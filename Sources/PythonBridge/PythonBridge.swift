import Foundation

/// Wraps the Python `rns_bridge` module. Every call hops onto a dedicated serial
/// queue (so all Python work is serialized — RNS internally still runs its own
/// background threads, but our Swift-initiated calls don't race) and uses
/// `PythonRuntime.shared.withGIL` to hold the GIL for the duration.
///
/// Events from RNS / LXMF callbacks land on a thread-safe Python queue.Queue;
/// Swift drains it via a Combine `Timer.publish` at ~5 Hz.
public final class PythonBridge: @unchecked Sendable {
    // Connection / send results bubble up as plain enums; the SwiftUI layer
    // turns them into user-facing strings.
    public struct LocalInfo: Equatable, Sendable {
        public let identityHash: String
        public let destinationHash: String
        public init(identityHash: String, destinationHash: String) {
            self.identityHash = identityHash
            self.destinationHash = destinationHash
        }
    }

    public enum BridgeError: LocalizedError {
        case notStarted
        case pythonException(String)
        case marshallingFailure(String)

        public var errorDescription: String? {
            switch self {
            case .notStarted: return "Python bridge not started"
            case .pythonException(let m): return "Python error: \(m)"
            case .marshallingFailure(let m): return "Marshalling: \(m)"
            }
        }
    }

    public enum SendOutcome: Equatable, Sendable {
        case queued
        case requestingPath
        case badHash
        case notStarted
        case other(String)
    }

    public enum Event: Equatable, Sendable {
        case announce(destHash: String, displayName: String, aspect: String, publicKeysHex: String, t: Date)
        case inbound(sourceHash: String, content: String, title: String, t: Date)
        case state(String, t: Date)

        // RNS.Link events — used by lxst-swift for voice calls. The
        // Swift LXST state machine consumes these to drive its own
        // call lifecycle; Python is just the underlying Link pipe.
        case linkState(linkId: Int, state: String, reason: String, inbound: Bool, t: Date)
        case linkPacket(linkId: Int, data: Data, t: Date)
        case linkIdentified(linkId: Int, identityHashHex: String, t: Date)
    }

    private let queue = DispatchQueue(label: "network.columba.python", qos: .userInitiated)
    private var module: UnsafeMutablePointer<PyObject>?

    public init() {}

    // MARK: - Public API

    /// Initialize Reticulum + LXMRouter inside Python. Returns local hashes on success.
    ///
    /// `identityBytes` is the preferred path for production iOS — Swift reads the
    /// 64-byte identity blob from Keychain and hands it over here; Python loads it
    /// via `RNS.Identity.from_bytes()`, never touching the filesystem for keys.
    /// Pass `nil` to fall back to `identityPath` (file-on-disk; mainly for CLI / PoC).
    public func start(
        configDir: String,
        identityPath: String,
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

                // Positional args 0..2, then identity_bytes (None or bytes) at slot 3.
                // Swift wrote the RNS config file at <configDir>/config before this
                // call (see PythonConfigWriter); rns_bridge.py just reads it.
                let args = PyTuple_New(4)
                guard args != nil else { throw BridgeError.marshallingFailure("PyTuple_New") }
                defer { Py_DecRef(args) }

                let strings = [configDir, identityPath, displayName]
                for (idx, value) in strings.enumerated() {
                    guard let u = PyUnicode_FromString(value) else {
                        throw BridgeError.marshallingFailure("PyUnicode_FromString[\(idx)]")
                    }
                    PyTuple_SetItem(args, idx, u) // steals ref
                }

                // identity_bytes at slot 3: either Py_None or a bytes object.
                if let data = identityBytes, !data.isEmpty {
                    let bytesObj: UnsafeMutablePointer<PyObject>? = data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return nil }
                        return PyBytes_FromStringAndSize(base.assumingMemoryBound(to: CChar.self), raw.count)
                    }
                    guard let bytesObj else { throw BridgeError.marshallingFailure("PyBytes_FromStringAndSize") }
                    PyTuple_SetItem(args, 3, bytesObj) // steals ref
                } else {
                    PyTuple_SetItem(args, 3, ColumbaPy_None()) // steals ref
                }

                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                return try extractLocalInfo(result)
            }
        }
    }

    public func stop() async throws {
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

    public func resetIdentity(identityPath: String) async throws {
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

    /// Outcome of a one-shot NomadNet page fetch over RNS Link.
    /// Mirrors what `rns_bridge.fetch_nomadnet_page` returns.
    public struct NomadNetFetchResult: Sendable, Equatable {
        public enum Status: String, Sendable {
            case ok
            case noPath = "no-path"
            case linkFailed = "link-failed"
            case requestFailed = "request-failed"
            case timeout
            case badHash = "bad-hash"
            case notStarted = "not-started"
            case unknown
        }
        public let ok: Bool
        public let status: Status
        public let data: Data
        public let contentType: String

        public init(ok: Bool, status: Status, data: Data, contentType: String) {
            self.ok = ok
            self.status = status
            self.data = data
            self.contentType = contentType
        }
    }

    /// Establish an RNS Link to the destination, request `path`, wait up to
    /// `timeout` seconds for the response, tear down the link, and return
    /// the bytes. `formFields` is `nil` for a plain GET-style fetch or a
    /// dictionary for form submission (msgpack-packed on the Python side).
    public func fetchNomadNetPage(
        destHashHex: String,
        path: String,
        timeout: TimeInterval = 30.0,
        formFields: [String: String]? = nil
    ) async throws -> NomadNetFetchResult {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else {
                    return NomadNetFetchResult(ok: false, status: .notStarted, data: Data(), contentType: "")
                }
                guard let fn = PyObject_GetAttrString(module, "fetch_nomadnet_page") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                let args = PyTuple_New(4)!
                defer { Py_DecRef(args) }
                PyTuple_SetItem(args, 0, PyUnicode_FromString(destHashHex)!)
                PyTuple_SetItem(args, 1, PyUnicode_FromString(path)!)
                PyTuple_SetItem(args, 2, PyFloat_FromDouble(timeout))

                if let fields = formFields, !fields.isEmpty {
                    let dict = PyDict_New()!
                    for (k, v) in fields {
                        let pyk = PyUnicode_FromString(k)
                        let pyv = PyUnicode_FromString(v)
                        PyDict_SetItem(dict, pyk, pyv)
                        if let pyk { Py_DecRef(pyk) }
                        if let pyv { Py_DecRef(pyv) }
                    }
                    PyTuple_SetItem(args, 3, dict)
                } else {
                    PyTuple_SetItem(args, 3, ColumbaPy_None())
                }

                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }

                let ok = pyBoolFromDict(result, key: "ok") ?? false
                let statusStr = pyStringFromDict(result, key: "status") ?? ""
                let contentType = pyStringFromDict(result, key: "content_type") ?? ""

                // Extract bytes from the `data` key — Python returns a bytes object.
                var data = Data()
                if let dataObj = PyDict_GetItemString(result, "data") {
                    var buf: UnsafeMutablePointer<CChar>? = nil
                    var len: Py_ssize_t = 0
                    if PyBytes_AsStringAndSize(dataObj, &buf, &len) == 0, let buf, len > 0 {
                        data = Data(bytes: buf, count: Int(len))
                    }
                }
                let status = NomadNetFetchResult.Status(rawValue: statusStr) ?? .unknown
                return NomadNetFetchResult(ok: ok, status: status, data: data, contentType: contentType)
            }
        }
    }

    /// Outcome of an LXMF propagation-node sync. Mirrors what
    /// `rns_bridge.propagation_sync` returns.
    public struct PropagationSyncResult: Sendable, Equatable {
        public enum State: String, Sendable {
            case idle
            case pathRequested = "path_requested"
            case linkEstablishing = "link_establishing"
            case linkEstablished = "link_established"
            case requestSent = "request_sent"
            case receiving
            case responseReceived = "response_received"
            case complete
            case noPath = "no_path"
            case transferFailed = "transfer_failed"
            case noRouter = "no-router"
            case notStarted = "not-started"
            case noNode = "no-node"
            case unknown
        }
        public let ok: Bool
        public let state: State
        public let receivedMessages: Int
        public let reason: String
    }

    /// Set / clear the outbound LXMF propagation node. Pass empty string
    /// to clear. `stampCost` is the per-message stamp cost the node
    /// advertises (in its announce app_data); 0 if unknown.
    @discardableResult
    public func setPropagationNode(destHashHex: String, stampCost: Int = 0) async throws -> Bool {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return false }
                guard let fn = PyObject_GetAttrString(module, "set_propagation_node") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                let args = PyTuple_New(2)!
                defer { Py_DecRef(args) }
                PyTuple_SetItem(args, 0, PyUnicode_FromString(destHashHex)!)
                PyTuple_SetItem(args, 1, PyLong_FromLongLong(Int64(stampCost))!)
                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                return pyBoolFromDict(result, key: "ok") ?? false
            }
        }
    }

    /// Block until LXMF propagation-node sync completes or times out.
    public func propagationSync(timeout: TimeInterval = 60.0) async throws -> PropagationSyncResult {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else {
                    return PropagationSyncResult(ok: false, state: .notStarted, receivedMessages: 0, reason: "not-started")
                }
                guard let fn = PyObject_GetAttrString(module, "propagation_sync") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                guard let arg = PyFloat_FromDouble(timeout) else {
                    throw BridgeError.marshallingFailure("timeout")
                }
                guard let result = PyObject_CallOneArg(fn, arg) else {
                    Py_DecRef(arg)
                    throw BridgeError.pythonException(currentPythonException())
                }
                Py_DecRef(arg)
                defer { Py_DecRef(result) }
                let ok = pyBoolFromDict(result, key: "ok") ?? false
                let stateStr = pyStringFromDict(result, key: "state") ?? ""
                let reason = pyStringFromDict(result, key: "reason") ?? ""
                let count: Int = {
                    guard let v = PyDict_GetItemString(result, "received_messages") else { return 0 }
                    return Int(PyLong_AsLongLong(v))
                }()
                let state = PropagationSyncResult.State(rawValue: stateStr) ?? .unknown
                return PropagationSyncResult(ok: ok, state: state, receivedMessages: count, reason: reason)
            }
        }
    }

    /// Re-broadcast the LXMF delivery destination's announce with the
    /// given display name. Returns true on success.
    public func announce(displayName: String) async throws -> Bool {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return false }
                guard let fn = PyObject_GetAttrString(module, "announce") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                guard let arg = PyUnicode_FromString(displayName) else {
                    throw BridgeError.marshallingFailure("displayName")
                }
                guard let result = PyObject_CallOneArg(fn, arg) else {
                    Py_DecRef(arg)
                    throw BridgeError.pythonException(currentPythonException())
                }
                Py_DecRef(arg)
                defer { Py_DecRef(result) }
                return pyBoolFromDict(result, key: "ok") ?? false
            }
        }
    }

    public func sendOpportunistic(destHashHex: String, content: String) async throws -> SendOutcome {
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

    /// Decoded view of the Python `status()` snapshot. Mirrors the JSON
    /// rns_bridge.status_json returns. The Swift UI uses this to drive the
    /// "interface online / offline" badges in Network Status + Manage
    /// Interfaces without re-querying the C-level RNS Transport state.
    public struct StatusSnapshot: Decodable, Sendable {
        public let started: Bool
        public let interfaces: [InterfaceStatus]
        public let destinationTableSize: Int?
        public let pathTableSize: Int?

        public struct InterfaceStatus: Decodable, Sendable {
            /// Config section name (matches what PythonConfigWriter wrote).
            public let sectionName: String
            /// Friendly `"TCPInterface[section/host:port]"` representation.
            public let name: String
            public let online: Bool
            public let rxBytes: Int
            public let txBytes: Int

            enum CodingKeys: String, CodingKey {
                case sectionName = "section_name"
                case name
                case online
                case rxBytes = "rx_bytes"
                case txBytes = "tx_bytes"
            }
        }

        enum CodingKeys: String, CodingKey {
            case started
            case interfaces
            case destinationTableSize = "destination_table_size"
            case pathTableSize = "path_table_size"
        }
    }

    /// Read RNS Transport diagnostic info — interfaces, online state, table sizes.
    public func status() async -> StatusSnapshot? {
        let raw: String? = await withCheckedContinuation { cont in
            queue.async {
                let out = PythonRuntime.shared.withGIL { () -> String? in
                    guard let module = self.module else { return nil }
                    guard let fn = PyObject_GetAttrString(module, "status_json") else { return nil }
                    defer { Py_DecRef(fn) }
                    guard let args = PyTuple_New(0) else { return nil }
                    defer { Py_DecRef(args) }
                    guard let result = PyObject_CallObject(fn, args) else { return nil }
                    defer { Py_DecRef(result) }
                    guard let c = PyUnicode_AsUTF8(result) else { return nil }
                    return String(cString: c)
                }
                cont.resume(returning: out)
            }
        }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StatusSnapshot.self, from: data)
    }

    /// Drain pending events from the Python-side queue.Queue. Returns empty list
    /// if the bridge isn't started yet.
    public func drainEvents() async -> [Event] {
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
                let aspect = pyStringFromDict(item, key: "aspect") ?? ""
                let pubKeys = pyStringFromDict(item, key: "public_keys") ?? ""
                out.append(.announce(destHash: h, displayName: name, aspect: aspect, publicKeysHex: pubKeys, t: t))
            case "inbound":
                let h = pyStringFromDict(item, key: "source_hash") ?? ""
                let c = pyStringFromDict(item, key: "content") ?? ""
                let title = pyStringFromDict(item, key: "title") ?? ""
                out.append(.inbound(sourceHash: h, content: c, title: title, t: t))
            case "state":
                let v = pyStringFromDict(item, key: "value") ?? "?"
                out.append(.state(v, t: t))
            case "link_state":
                let linkId = pyIntFromDict(item, key: "link_id") ?? 0
                let state = pyStringFromDict(item, key: "state") ?? ""
                let reason = pyStringFromDict(item, key: "reason") ?? ""
                let inbound = pyBoolFromDict(item, key: "inbound") ?? false
                out.append(.linkState(linkId: linkId, state: state, reason: reason, inbound: inbound, t: t))
            case "link_packet":
                let linkId = pyIntFromDict(item, key: "link_id") ?? 0
                let hex = pyStringFromDict(item, key: "data_hex") ?? ""
                let data = Data(hexEncoded: hex) ?? Data()
                out.append(.linkPacket(linkId: linkId, data: data, t: t))
            case "link_identified":
                let linkId = pyIntFromDict(item, key: "link_id") ?? 0
                let identity = pyStringFromDict(item, key: "identity_hash") ?? ""
                out.append(.linkIdentified(linkId: linkId, identityHashHex: identity, t: t))
            default:
                continue
            }
        }
        return out
    }

    private func pyIntFromDict(_ d: UnsafeMutablePointer<PyObject>, key: String) -> Int? {
        guard let item = PyDict_GetItemString(d, key) else { return nil }
        let v = PyLong_AsLongLong(item)
        if v == -1 && PyErr_Occurred() != nil { PyErr_Clear(); return nil }
        return Int(v)
    }

    // MARK: - RNS.Link ops (voice calls)

    /// Open an outbound RNS.Link to a destination. Default aspect is
    /// `lxst.telephony` (voice); pass another aspect string for other
    /// Link-based protocols (e.g. NomadNet page browsing already uses
    /// its own one-shot path, so this is currently voice-only).
    ///
    /// Returns the Python-side `link_id` on success. A subsequent
    /// `.linkState(linkId:, state: "established")` event fires once
    /// the link is up.
    public func openLink(destHashHex: String, aspect: String = "lxst.telephony") async throws -> (ok: Bool, linkId: Int, reason: String) {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else {
                    return (false, 0, "not-started")
                }
                guard let fn = PyObject_GetAttrString(module, "open_link") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                let args = PyTuple_New(2)!
                defer { Py_DecRef(args) }
                PyTuple_SetItem(args, 0, PyUnicode_FromString(destHashHex)!)
                PyTuple_SetItem(args, 1, PyUnicode_FromString(aspect)!)
                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                let ok = pyBoolFromDict(result, key: "ok") ?? false
                let linkId = pyIntFromDict(result, key: "link_id") ?? 0
                let reason = pyStringFromDict(result, key: "reason") ?? ""
                return (ok, linkId, reason)
            }
        }
    }

    /// Send opaque bytes over an open Link. Returns true on success.
    @discardableResult
    public func linkSend(linkId: Int, data: Data) async throws -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return false }
                guard let fn = PyObject_GetAttrString(module, "link_send") else { return false }
                defer { Py_DecRef(fn) }
                let args = PyTuple_New(2)!
                defer { Py_DecRef(args) }
                PyTuple_SetItem(args, 0, PyLong_FromLongLong(Int64(linkId)))
                PyTuple_SetItem(args, 1, PyUnicode_FromString(hex)!)
                guard let result = PyObject_CallObject(fn, args) else { return false }
                defer { Py_DecRef(result) }
                return pyBoolFromDict(result, key: "ok") ?? false
            }
        }
    }

    /// Identify our local identity on the Link to the remote.
    @discardableResult
    public func linkIdentify(linkId: Int) async throws -> Bool {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return false }
                guard let fn = PyObject_GetAttrString(module, "link_identify") else { return false }
                defer { Py_DecRef(fn) }
                let args = PyTuple_New(1)!
                defer { Py_DecRef(args) }
                PyTuple_SetItem(args, 0, PyLong_FromLongLong(Int64(linkId)))
                guard let result = PyObject_CallObject(fn, args) else { return false }
                defer { Py_DecRef(result) }
                return pyBoolFromDict(result, key: "ok") ?? false
            }
        }
    }

    /// Tear down a Link from our side.
    @discardableResult
    public func linkTeardown(linkId: Int) async throws -> Bool {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return false }
                guard let fn = PyObject_GetAttrString(module, "link_teardown") else { return false }
                defer { Py_DecRef(fn) }
                let args = PyTuple_New(1)!
                defer { Py_DecRef(args) }
                PyTuple_SetItem(args, 0, PyLong_FromLongLong(Int64(linkId)))
                guard let result = PyObject_CallObject(fn, args) else { return false }
                defer { Py_DecRef(result) }
                return pyBoolFromDict(result, key: "ok") ?? false
            }
        }
    }
}

private extension Data {
    /// Decode a hex-encoded string into raw bytes. Tolerates uppercase
    /// + mixed case. Returns nil if length is odd or any character is
    /// out of range.
    init?(hexEncoded hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self = out
    }
}
