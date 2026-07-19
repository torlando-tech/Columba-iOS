import Foundation

// PythonBridge can't import ColumbaApp's DiagLog (lives in the app target);
// duplicate the writer here for status-side diagnostics. Same file path
// (Documents/diag.log) so output interleaves with the rest.
private func DiagLog_status(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] [PY-STATUS] \(message)\n"
    NSLog("%@", "[PY-STATUS] \(message)")
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    guard let url = docs?.appendingPathComponent("diag.log"),
          let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path) {
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        }
    } else {
        try? data.write(to: url)
    }
}

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
        /// Successfully queued. `messageHash` is the real LXMF message hash hex
        /// (populated once Python packs the message); empty if unavailable.
        /// Callers persist the outbound message under this so a later
        /// `.delivery` event can match it.
        case queued(messageHash: String)
        case requestingPath
        case badHash
        case notStarted
        case other(String)
    }

    public enum Event: Equatable, Sendable {
        case announce(destHash: String, appDataHex: String, aspect: String, publicKeysHex: String, interfaceName: String, hops: Int, t: Date)
        case inbound(sourceHash: String, messageHash: String, content: String, title: String, fieldsHex: String, t: Date)
        case state(String, t: Date)

        /// Delivery / failure proof for an outbound message, keyed by its LXMF
        /// message hash hex. `state` is "delivered" or "failed". Drives the
        /// chat UI's double-check / failed indicator.
        case delivery(messageHash: String, state: String, t: Date)

        // RNS.Link events — used by lxst-swift for voice calls. The
        // Swift LXST state machine consumes these to drive its own
        // call lifecycle; Python is just the underlying Link pipe.
        case linkState(linkId: Int, state: String, reason: String, inbound: Bool, t: Date)
        case linkPacket(linkId: Int, data: Data, t: Date)
        case linkIdentified(linkId: Int, identityHashHex: String, t: Date)
    }

    private let queue = DispatchQueue(label: "network.columba.python", qos: .userInitiated)
    /// Dedicated queue for long-blocking poll-style Python calls (e.g.
    /// `propagationSync`, which blocks up to its timeout). Running these on the
    /// main `queue` would starve every other bridge call for the whole timeout,
    /// since `queue` is serial. The blocking Python poll releases the GIL
    /// between iterations (`time.sleep`), so short calls on `queue` acquire the
    /// GIL and run promptly while a sync is in flight. Two queues into CPython
    /// is safe: `withGIL` (PyGILState_Ensure/Release) serializes all Python
    /// access regardless of thread — the same pattern the BLE callback path
    /// already relies on.
    private let blockingQueue = DispatchQueue(label: "network.columba.python.blocking", qos: .userInitiated)
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
        // Runs on `blockingQueue`, not the main serial `queue`: the Python
        // fetch blocks up to `timeout` inside link_ready/response_ready waits,
        // and on the shared queue that would stall drainEvents + every other
        // bridge call for the duration — the same starvation propagationSync
        // avoids.
        try await runOnQueue(on: blockingQueue) { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else {
                    return NomadNetFetchResult(ok: false, status: .notStarted, data: Data(), contentType: "")
                }
                guard let fn = PyObject_GetAttrString(module, "fetch_nomadnet_page") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                guard let args = PyTuple_New(4) else { throw BridgeError.marshallingFailure("PyTuple_New") }
                defer { Py_DecRef(args) }
                guard let nnDest = PyUnicode_FromString(destHashHex),
                      let nnPath = PyUnicode_FromString(path) else {
                    throw BridgeError.marshallingFailure("PyUnicode_FromString")
                }
                PyTuple_SetItem(args, 0, nnDest)
                PyTuple_SetItem(args, 1, nnPath)
                PyTuple_SetItem(args, 2, PyFloat_FromDouble(timeout))

                if let fields = formFields, !fields.isEmpty {
                    guard let dict = PyDict_New() else { throw BridgeError.marshallingFailure("PyDict_New") }
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
                guard let args = PyTuple_New(2) else { throw BridgeError.marshallingFailure("PyTuple_New") }
                defer { Py_DecRef(args) }
                guard let pnDest = PyUnicode_FromString(destHashHex),
                      let pnCost = PyLong_FromLongLong(Int64(stampCost)) else {
                    throw BridgeError.marshallingFailure("PyUnicode/PyLong")
                }
                PyTuple_SetItem(args, 0, pnDest)
                PyTuple_SetItem(args, 1, pnCost)
                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                return pyBoolFromDict(result, key: "ok") ?? false
            }
        }
    }

    /// Block until LXMF propagation-node sync completes or times out.
    ///
    /// Runs on `blockingQueue`, not the main serial `queue`: the underlying
    /// Python poll blocks up to `timeout`, and on the shared queue that would
    /// stall every other bridge call (announce, send, …) for the duration.
    public func propagationSync(timeout: TimeInterval = 60.0) async throws -> PropagationSyncResult {
        try await runOnQueue(on: blockingQueue) { [self] in
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
        try await callAnnounce(functionName: "announce", displayName: displayName)
    }

    /// Re-broadcast the LXST telephony destination's announce so peers can
    /// discover us for voice calls. Returns true on success.
    public func announceTelephony(displayName: String) async throws -> Bool {
        try await callAnnounce(functionName: "announce_telephony", displayName: displayName)
    }

    /// Shared CPython call shape for the two announce variants.
    private func callAnnounce(functionName: String, displayName: String) async throws -> Bool {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return false }
                guard let fn = PyObject_GetAttrString(module, functionName) else {
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

    /// Send an LXMF message via the Python bridge. `method` selects LXMF's
    /// desired-method (opportunistic / direct / propagated); the function name
    /// stays `sendOpportunistic` historically because that was the only mode
    /// when the Swift surface was first carved.
    public func sendOpportunistic(destHashHex: String, content: String, fieldsHex: String = "",
                                  method: String = "opportunistic") async throws -> SendOutcome {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return .notStarted }
                guard let fn = PyObject_GetAttrString(module, "send_opportunistic") else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                guard let args = PyTuple_New(4) else { throw BridgeError.marshallingFailure("PyTuple_New") }
                defer { Py_DecRef(args) }
                guard let soDest = PyUnicode_FromString(destHashHex),
                      let soContent = PyUnicode_FromString(content),
                      let soFields = PyUnicode_FromString(fieldsHex),
                      let soMethod = PyUnicode_FromString(method) else {
                    throw BridgeError.marshallingFailure("PyUnicode_FromString")
                }
                PyTuple_SetItem(args, 0, soDest)
                PyTuple_SetItem(args, 1, soContent)
                PyTuple_SetItem(args, 2, soFields)
                PyTuple_SetItem(args, 3, soMethod)
                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                let reason = pyStringFromDict(result, key: "reason") ?? "unknown"
                let ok = pyBoolFromDict(result, key: "ok") ?? false
                if ok {
                    let hash = pyStringFromDict(result, key: "message_hash") ?? ""
                    return .queued(messageHash: hash)
                }
                switch reason {
                case "requesting-path": return .requestingPath
                case "bad-hash": return .badHash
                case "not-started": return .notStarted
                default: return .other(reason)
                }
            }
        }
    }

    /// Hot-add or hot-remove a single interface on the *running* Reticulum
    /// stack — no restart. Calls `rns_bridge.add_interface(name)` /
    /// `remove_interface(name)`, which attach/detach against the live
    /// `RNS.Transport`. `name` is the config section name (see
    /// `PythonConfigWriter.sectionName(for:)`); the caller must have written
    /// the full config file first so `add` can read the new section.
    ///
    /// Returns the Python `{"ok", "reason"}` outcome. Throws only on a hard
    /// bridge/marshalling error — a failed add (bad config, unreachable
    /// endpoint) comes back as `(ok: false, reason: ...)`, never a crash.
    public func applyInterface(name: String, add: Bool) async throws -> (ok: Bool, reason: String) {
        try await runOnQueue { [self] in
            try PythonRuntime.shared.withGIL { [self] in
                guard let module = self.module else { return (false, "not-started") }
                let fnName = add ? "add_interface" : "remove_interface"
                guard let fn = PyObject_GetAttrString(module, fnName) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(fn) }
                guard let args = PyTuple_New(1) else { throw BridgeError.marshallingFailure("PyTuple_New") }
                defer { Py_DecRef(args) }
                guard let aiName = PyUnicode_FromString(name) else {
                    throw BridgeError.marshallingFailure("PyUnicode_FromString")
                }
                PyTuple_SetItem(args, 0, aiName) // steals ref
                guard let result = PyObject_CallObject(fn, args) else {
                    throw BridgeError.pythonException(currentPythonException())
                }
                defer { Py_DecRef(result) }
                let ok = pyBoolFromDict(result, key: "ok") ?? false
                let reason = pyStringFromDict(result, key: "reason") ?? "unknown"
                return (ok, reason)
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
            /// Dynamically-spawned interfaces (AutoInterfacePeer, etc.) can
            /// have `name=None` upstream, which serializes as JSON null;
            /// tolerate it by decoding optional and substituting "".
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

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.sectionName = (try? c.decode(String?.self, forKey: .sectionName)) ?? ""
                self.name = (try? c.decode(String?.self, forKey: .name)) ?? ""
                self.online = (try? c.decode(Bool.self, forKey: .online)) ?? false
                self.rxBytes = (try? c.decode(Int.self, forKey: .rxBytes)) ?? 0
                self.txBytes = (try? c.decode(Int.self, forKey: .txBytes)) ?? 0
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
                    guard let fn = PyObject_GetAttrString(module, "status_json") else {
                        let exc = self.currentPythonException()
                        DiagLog_status("status_json attr lookup failed: \(exc)")
                        return nil
                    }
                    defer { Py_DecRef(fn) }
                    guard let args = PyTuple_New(0) else { return nil }
                    defer { Py_DecRef(args) }
                    guard let result = PyObject_CallObject(fn, args) else {
                        let exc = self.currentPythonException()
                        DiagLog_status("status_json call raised: \(exc)")
                        return nil
                    }
                    defer { Py_DecRef(result) }
                    guard let c = PyUnicode_AsUTF8(result) else {
                        DiagLog_status("status_json returned non-str")
                        return nil
                    }
                    return String(cString: c)
                }
                cont.resume(returning: out)
            }
        }
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(StatusSnapshot.self, from: data)
        } catch {
            DiagLog_status("decode failed: \(error) raw=\(raw.prefix(200))")
            return nil
        }
    }

    /// Invoke a no-arg module-level function in `rns_bridge` that returns
    /// a Python string. Used for diagnostic hooks that want to surface
    /// a string back to Swift (e.g., interface-load error messages).
    /// Returns nil on Python error or if the function doesn't exist.
    public func callModuleFunctionReturningString(name: String) async -> String? {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                let out = PythonRuntime.shared.withGIL { () -> String? in
                    guard let module = self.module else { return nil }
                    guard let fn = PyObject_GetAttrString(module, name) else {
                        PyErr_Clear()
                        return nil
                    }
                    defer { Py_DecRef(fn) }
                    guard let args = PyTuple_New(0) else { return nil }
                    defer { Py_DecRef(args) }
                    guard let r = PyObject_CallObject(fn, args) else {
                        PyErr_Print()
                        return nil
                    }
                    defer { Py_DecRef(r) }
                    guard let c = PyUnicode_AsUTF8(r) else { return nil }
                    return String(cString: c)
                }
                cont.resume(returning: out)
            }
        }
    }

    /// Invoke a no-arg module-level function in `rns_bridge`. Returns true if
    /// the call completes without raising; the function's return value is
    /// discarded. Convenience for test hooks and one-shot helpers.
    public func callModuleFunctionNoArgs(name: String) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                let ok = PythonRuntime.shared.withGIL { () -> Bool in
                    guard let module = self.module else { return false }
                    guard let fn = PyObject_GetAttrString(module, name) else {
                        PyErr_Clear()
                        return false
                    }
                    defer { Py_DecRef(fn) }
                    guard let args = PyTuple_New(0) else { return false }
                    defer { Py_DecRef(args) }
                    guard let r = PyObject_CallObject(fn, args) else {
                        PyErr_Print()
                        return false
                    }
                    Py_DecRef(r)
                    return true
                }
                cont.resume(returning: ok)
            }
        }
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

    private func runOnQueue<T: Sendable>(
        on targetQueue: DispatchQueue? = nil,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            (targetQueue ?? queue).async {
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
                let appData = pyStringFromDict(item, key: "app_data") ?? ""
                let aspect = pyStringFromDict(item, key: "aspect") ?? ""
                let pubKeys = pyStringFromDict(item, key: "public_keys") ?? ""
                let ifaceName = pyStringFromDict(item, key: "interface_name") ?? ""
                let hops = pyIntFromDict(item, key: "hops") ?? 0
                out.append(.announce(destHash: h, appDataHex: appData, aspect: aspect, publicKeysHex: pubKeys, interfaceName: ifaceName, hops: hops, t: t))
            case "inbound":
                let h = pyStringFromDict(item, key: "source_hash") ?? ""
                let messageHash = pyStringFromDict(item, key: "message_hash") ?? ""
                let c = pyStringFromDict(item, key: "content") ?? ""
                let title = pyStringFromDict(item, key: "title") ?? ""
                let fieldsHex = pyStringFromDict(item, key: "fields_hex") ?? ""
                out.append(.inbound(sourceHash: h, messageHash: messageHash, content: c, title: title, fieldsHex: fieldsHex, t: t))
            case "state":
                let v = pyStringFromDict(item, key: "value") ?? "?"
                out.append(.state(v, t: t))
            case "delivery":
                let h = pyStringFromDict(item, key: "message_hash") ?? ""
                let state = pyStringFromDict(item, key: "state") ?? ""
                out.append(.delivery(messageHash: h, state: state, t: t))
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
                guard let args = PyTuple_New(2) else { throw BridgeError.marshallingFailure("PyTuple_New") }
                defer { Py_DecRef(args) }
                guard let olDest = PyUnicode_FromString(destHashHex),
                      let olAspect = PyUnicode_FromString(aspect) else {
                    throw BridgeError.marshallingFailure("PyUnicode_FromString")
                }
                PyTuple_SetItem(args, 0, olDest)
                PyTuple_SetItem(args, 1, olAspect)
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
                guard let args = PyTuple_New(2) else { return false }
                defer { Py_DecRef(args) }
                guard let lsHex = PyUnicode_FromString(hex) else { return false }
                PyTuple_SetItem(args, 0, PyLong_FromLongLong(Int64(linkId)))
                PyTuple_SetItem(args, 1, lsHex)
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
                guard let args = PyTuple_New(1) else { return false }
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
                guard let args = PyTuple_New(1) else { return false }
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

// MARK: - BLE callback invocation
//
// Direction: Swift → Python. Used by SwiftBLEBridge's CoreBluetooth delegate
// methods to fire the upstream BLEInterface callbacks (`on_device_discovered`,
// `on_device_connected`, etc.). Python registers callables under named slots
// via `rns_bridge.set_ble_callback(slot, callable)`; Swift looks them up
// here and invokes them under the GIL.
//
// The synchronous variant (`invokeBLECallbackBoolSync`) backs upstream's
// `on_duplicate_identity_detected` which must return a bool BEFORE the
// driver completes a connection. All other callbacks are fire-and-forget.

/// Argument shape for BLE callbacks. Mirror of the small set of types
/// upstream BLEInterface receives: addresses (str), data (bytes),
/// identity hashes (str hex), MTU (int), service UUIDs (list[str]),
/// severity strings, etc.
public enum BLEArg: Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case bytes(Data)
    case stringList([String])
    case none
}

public extension PythonBridge {

    /// Fire a Python BLE callback under the given slot name. Args are converted
    /// to PyObjects, packed into a tuple, and passed via `PyObject_CallObject`.
    /// Fire-and-forget: any return value is discarded.
    ///
    /// Safe to call from any Swift queue — internally hops to the Python serial
    /// queue and acquires the GIL.
    func invokeBLECallback(slot: String, args: [BLEArg]) {
        queue.async { [self] in
            _ = PythonRuntime.shared.withGIL { () -> Int in
                self.invokeBLECallbackLocked(slot: slot, args: args)
                return 0
            }
        }
    }

    /// Synchronous bool-return invocation. Backs upstream's
    /// `on_duplicate_identity_detected(addr, identity_bytes) -> bool`. The
    /// CoreBluetooth delegate calling this is expected to block on the result;
    /// we sync to the Python queue, acquire the GIL, invoke, and return the bool.
    ///
    /// MUST NOT be called from the Python queue itself (re-entrancy would
    /// deadlock). The BLE queue is a different DispatchQueue, so calling from
    /// CB delegate methods is safe.
    func invokeBLECallbackBoolSync(slot: String, args: [BLEArg]) -> Bool {
        queue.sync { [self] in
            PythonRuntime.shared.withGIL { () -> Bool in
                let result = self.invokeBLECallbackLocked(slot: slot, args: args, wantResult: true)
                if let pyResult = result {
                    defer { Py_DecRef(pyResult) }
                    return PyObject_IsTrue(pyResult) == 1
                }
                return false
            }
        }
    }

    /// MUST be called with the GIL held. Returns the raw `PyObject*` result if
    /// `wantResult` is true (caller owns the ref), else nil. `getterName` selects
    /// the rns_bridge slot-lookup function (`_ble_get_callback` for the mesh).
    @discardableResult
    private func invokeBLECallbackLocked(
        slot: String,
        args: [BLEArg],
        wantResult: Bool = false,
        getterName: String = "_ble_get_callback"
    ) -> UnsafeMutablePointer<PyObject>? {
        guard let module = self.module else { return nil }
        guard let getterFn = PyObject_GetAttrString(module, getterName) else {
            PyErr_Clear()
            return nil
        }
        defer { Py_DecRef(getterFn) }
        guard let slotStr = PyUnicode_FromString(slot) else { return nil }
        guard let callable = PyObject_CallOneArg(getterFn, slotStr) else {
            Py_DecRef(slotStr)
            PyErr_Clear()
            return nil
        }
        Py_DecRef(slotStr)
        defer { Py_DecRef(callable) }
        // None means "no callback registered" — silent no-op.
        if isNone(callable) { return nil }
        guard let argsTuple = bleArgsToPyTuple(args) else { return nil }
        defer { Py_DecRef(argsTuple) }
        guard let result = PyObject_CallObject(callable, argsTuple) else {
            // Print the traceback to stderr so RNS log captures it; clear
            // the error indicator so subsequent Python calls don't see it.
            PyErr_Print()
            return nil
        }
        if wantResult { return result }
        Py_DecRef(result)
        return nil
    }

    private func bleArgsToPyTuple(_ args: [BLEArg]) -> UnsafeMutablePointer<PyObject>? {
        guard let tuple = PyTuple_New(args.count) else { return nil }
        for (idx, arg) in args.enumerated() {
            guard let pyobj = bleArgToPy(arg) else {
                Py_DecRef(tuple)
                return nil
            }
            PyTuple_SetItem(tuple, idx, pyobj) // steals ref
        }
        return tuple
    }

    private func bleArgToPy(_ arg: BLEArg) -> UnsafeMutablePointer<PyObject>? {
        switch arg {
        case .string(let s):
            return PyUnicode_FromString(s)
        case .int(let i):
            return PyLong_FromLongLong(Int64(i))
        case .bool(let b):
            return b ? ColumbaPy_True() : ColumbaPy_False()
        case .bytes(let data):
            return data.withUnsafeBytes { raw -> UnsafeMutablePointer<PyObject>? in
                guard let base = raw.baseAddress else {
                    return PyBytes_FromStringAndSize(nil, 0)
                }
                return PyBytes_FromStringAndSize(
                    base.assumingMemoryBound(to: CChar.self),
                    raw.count
                )
            }
        case .stringList(let strs):
            guard let list = PyList_New(strs.count) else { return nil }
            for (idx, s) in strs.enumerated() {
                guard let u = PyUnicode_FromString(s) else {
                    Py_DecRef(list)
                    return nil
                }
                PyList_SetItem(list, idx, u) // steals ref
            }
            return list
        case .none:
            return ColumbaPy_None()
        }
    }

    private func isNone(_ obj: UnsafeMutablePointer<PyObject>) -> Bool {
        guard let none = ColumbaPy_None() else { return false }
        defer { Py_DecRef(none) }
        return obj == none
    }
}
