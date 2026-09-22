//
//  ControlChannel.swift
//  ColumbaNode
//
//  The bounded app<->NE control channel (contract 6): `[0xF5, 0x02]` magic +
//  UTF-8 JSON, hard 64 KiB envelope cap INCLUDING the 2 framing bytes. The
//  complete command body is never inline - `admit` carries only the commandID,
//  which the node owner resolves against the shared store's command ledger
//  (contract 3.3, 6).
//
//  This is the engine-agnostic seam: it knows nothing about RNS. Python RNS,
//  Reticulum-Go, or microReticulum all sit BEHIND a `NodeEngine` (Engine.swift);
//  the framing + envelope rules here are shared by every implementation.
//

import Foundation
import CoreFoundation

public enum ControlChannelError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case unknownFramingVersion(UInt8)
    case oversize(UInt)          // envelope > 64 KiB
    case emptyPayload
    case undecodable(String)     // parse error detail (never a secret)

    public var description: String {
        switch self {
        case .badMagic: return "frame does not begin with 0xF5 0x02"
        case let .unknownFramingVersion(v): return "unknown control framing version 0x\(String(format: "%02X", v))"
        case let .oversize(n): return "envelope \(n) bytes exceeds the 64 KiB cap"
        case .emptyPayload: return "frame has no JSON payload"
        case let .undecodable(d): return "undecodable control payload: \(d)"
        }
    }
}

public enum ControlChannel {
    /// Contract framing magic (contract 6): 0xF5 identifies control, 0x02 this version.
    public static let magic: [UInt8] = [0xF5, 0x02]
    /// Hard envelope cap including framing (contract 6).
    public static let maxEnvelopeBytes: UInt = 65_536   // 64 KiB

    /// Encode a request into a framed envelope ready to hand to the transport.
    public static func encode(request: RequestBody, requestID: RequestID? = nil) throws -> Data {
        let id = requestID ?? RequestID()
        var obj: [String: JsonValue] = [
            "requestID": .string(id.wire),
            "body": request.jsonValue,
        ]
        let data = JsonValue.object(obj).canonicalData()
        return try frame(payload: data)
    }

    /// Encode a reply into a framed envelope.
    public static func encode(reply: Reply) throws -> Data {
        let data = reply.jsonValue.canonicalData()
        return try frame(payload: data)
    }

    /// Build an envelope: magic + payload, enforcing the hard cap.
    static func frame(payload: Data) throws -> Data {
        let envelope = UInt(magic.count) + UInt(payload.count)
        guard envelope <= maxEnvelopeBytes else {
            throw ControlChannelError.oversize(envelope)
        }
        return Data(magic) + payload
    }

    /// Decode the framing of an incoming envelope and return the raw JSON payload.
    /// A frame beginning 0xF5 with an unknown/truncated version is a hard
    /// control-protocol error - it must never fall through to a legacy path
    /// (contract 6).
    public static func payload(from envelope: Data) throws -> Data {
        let bytes = [UInt8](envelope)
        guard bytes.count >= magic.count else {
            throw ControlChannelError.badMagic
        }
        if bytes[0] != magic[0] {
            throw ControlChannelError.badMagic
        }
        if bytes[1] != magic[1] {
            // 0xF5 but an unknown/truncated version: hard control-protocol error,
            // never falls through to a legacy path (contract 6).
            throw ControlChannelError.unknownFramingVersion(bytes[1])
        }
        let payload = Data(bytes.dropFirst(magic.count))
        guard !payload.isEmpty else { throw ControlChannelError.emptyPayload }
        return payload
    }

    /// Decode a full request from a framed envelope.
    public static func decodeRequest(from envelope: Data) throws -> (requestID: RequestID, body: RequestBody) {
        let payload = try payload(from: envelope)
        return try decodeRequest(fromPayload: payload)
    }

    public static func decodeRequest(fromPayload payload: Data) throws -> (requestID: RequestID, body: RequestBody) {
        guard let json = try jsonFrom(payload: payload) else {
            throw ControlChannelError.undecodable("not a JSON object")
        }
        let tag = string(json["body"]?["tag"]) ?? ""
        guard let body = try decodeBody(tag: tag, value: json["body"]?["value"]) else {
            throw ControlChannelError.undecodable("unknown request body tag '\(tag)'")
        }
        let requestID = RequestID(wire: string(json["requestID"]) ?? "")
            ?? RequestID()
        return (requestID, body)
    }

    /// Decode a full reply from a framed envelope.
    public static func decodeReply(from envelope: Data) throws -> Reply {
        let payload = try payload(from: envelope)
        guard let json = try jsonFrom(payload: payload) else {
            throw ControlChannelError.undecodable("not a JSON object")
        }
        let requestID = RequestID(wire: string(json["requestID"]) ?? "") ?? RequestID()
        let storeEpoch = string(json["storeEpoch"]).flatMap(StoreEpoch.init(wire:))
        let bootID = string(json["bootID"]).flatMap(BootID.init(wire:))
        let resultTag = string(json["result"]?["tag"]) ?? ""
        let resultValue = json["result"]?["value"]   // the union's {tag, value} object

        let result: Reply.Result
        if resultTag == "success" {
            // ReplyValue is itself tagged; its tag + payload live inside result.value.
            let innerTag = string(resultValue?["tag"]) ?? ""
            let innerValue = resultValue?["value"]
            guard let value = try decodeReplyValue(tag: innerTag, value: innerValue) else {
                throw ControlChannelError.undecodable("unknown reply value tag '\(innerTag)'")
            }
            result = .success(value)
        } else if resultTag == "failure", let err = decodeError(resultValue) {
            result = .failure(err)
        } else {
            throw ControlChannelError.undecodable("unknown reply result tag '\(resultTag)'")
        }
        return Reply(requestID: requestID, storeEpoch: storeEpoch, bootID: bootID, result: result)
    }

    // MARK: - tagged-union decode

    private static func decodeBody(tag: String, value: JsonValue?) throws -> RequestBody? {
        switch tag {
        case "hello":
            let versions = (value?["versions"]?.arrayValue ?? []).compactMap { $0.asVersion() }
            let min = value?["schemaMin"]?.uintValue ?? 0
            let max = value?["schemaMax"]?.uintValue ?? 0
            return .hello(versions: versions, schemaMin: min, schemaMax: max)
        case "admit":
            let session = try decodeSession(value?["session"])
            let cmd = CommandID(wire: string(value?["commandID"]) ?? "")
            guard let session, let cmd else { return nil }
            return .admit(session: session, commandID: cmd)
        case "query":
            let session = try decodeSession(value?["session"])
            guard let session, let q = try decodeQuery(value?["query"]) else { return nil }
            return .query(session: session, query: q)
        case "act":
            let session = try decodeSession(value?["session"])
            let actionID = ActionID(wire: string(value?["actionID"]) ?? "")
            guard let session, let actionID, let a = try decodeAction(value?["action"]) else { return nil }
            return .act(session: session, actionID: actionID, action: a)
        default:
            return nil
        }
    }

    private static func decodeReplyValue(tag: String, value: JsonValue?) throws -> ReplyValue? {
        switch tag {
        case "hello":
            guard let d = try decodeDescriptor(value) else { return nil }
            return .hello(d)
        case "admission":
            guard let r = try decodeCommandRecord(value) else { return nil }
            return .admission(r)
        case "query":
            guard let r = try decodeQueryResult(value) else { return nil }
            return .query(r)
        case "action":
            guard let r = try decodeActionResult(value) else { return nil }
            return .action(r)
        default:
            return nil
        }
    }

    // MARK: - value decoders

    private static func decodeSession(_ v: JsonValue?) throws -> Session? {
        guard let version = v?["version"]?.asVersion(),
              let epoch = StoreEpoch(wire: string(v?["storeEpoch"]) ?? ""),
              let boot = BootID(wire: string(v?["bootID"]) ?? "") else { return nil }
        return Session(version: version, storeEpoch: epoch, bootID: boot)
    }

    private static func decodeQuery(_ v: JsonValue?) throws -> Query? {
        let tag = string(v?["tag"]) ?? ""
        switch tag {
        case "nodeState": return .nodeState
        case "identities": return .identities
        case "identity":
            guard let id = IdentityID(wire: string(v?["value"]?["identityID"]) ?? "") else { return nil }
            return .identity(id)
        case "operation":
            guard let id = OperationID(wire: string(v?["value"]?["operationID"]) ?? "") else { return nil }
            return .operation(id)
        case "reachability":
            guard let d = DestinationHash(hex: string(v?["value"]?["destination"]) ?? "") else { return nil }
            return .reachability(destination: d)
        default: return nil
        }
    }

    private static func decodeAction(_ v: JsonValue?) throws -> Action? {
        let tag = string(v?["tag"]) ?? ""
        switch tag {
        case "start": return .start
        case "stop": return .stop
        case "transmitGate":
            guard let id = IdentityID(wire: string(v?["value"]?["identityID"]) ?? "") else { return nil }
            let enabled = v?["value"]?["enabled"]?.boolValue ?? false
            return .transmitGate(id, enabled: enabled)
        default: return nil
        }
    }

    private static func decodeDescriptor(_ v: JsonValue?) throws -> Descriptor? {
        guard let version = v?["version"]?.asVersion(),
              let epoch = StoreEpoch(wire: string(v?["storeEpoch"]) ?? ""),
              let boot = BootID(wire: string(v?["bootID"]) ?? "") else { return nil }
        let capsArr = v?["capabilities"]?.arrayValue ?? []
        let caps = capsArr.compactMap { cv -> Capability? in
            guard let f = Feature(rawValue: string(cv["feature"]) ?? "") else { return nil }
            let support = Capability.Support(rawValue: string(cv["support"]) ?? "") ?? .unsupported
            let avail = Availability(rawValue: string(cv["availability"]) ?? "") ?? .disabled
            return Capability(feature: f, support: support, availability: avail, reason: string(cv["reason"]))
        }
        let backend = BuildInfo(
            name: string(v?["backend"]?["name"]) ?? "",
            revision: string(v?["backend"]?["revision"]) ?? "",
            adapterRevision: string(v?["backend"]?["adapterRevision"]) ?? "")
        let phase = RuntimeSnapshot.Phase(rawValue: string(v?["runtime"]?["phase"]) ?? "") ?? .starting
        let conn = RuntimeSnapshot.Connectivity(rawValue: string(v?["runtime"]?["connectivity"]) ?? "") ?? .unknown
        let enabledArr = v?["runtime"]?["enabledIdentities"]?.arrayValue ?? []
        let enabled = enabledArr.compactMap { IdentityID(wire: string($0) ?? "") }
        let runtime = RuntimeSnapshot(
            bootID: boot, phase: phase,
            desiredEnabled: v?["runtime"]?["desiredEnabled"]?.boolValue ?? false,
            actualEnabled: v?["runtime"]?["actualEnabled"]?.boolValue ?? false,
            enabledIdentities: enabled, connectivity: conn,
            observedAt: Instant(v?["runtime"]?["observedAt"]?.intValue ?? 0))
        return Descriptor(version: version, storeEpoch: epoch, bootID: boot,
                          storeSchema: v?["storeSchema"]?.uintValue ?? 0,
                          capabilities: caps, backend: backend, runtime: runtime)
    }

    private static func decodeCommandRecord(_ v: JsonValue?) throws -> CommandRecord? {
        guard let cmd = CommandID(wire: string(v?["commandID"]) ?? ""),
              let digest = Digest(hex: string(v?["bodyDigest"]) ?? ""),
              let disp = CommandRecord.Disposition(rawValue: string(v?["disposition"]) ?? "") else { return nil }
        let op = string(v?["operationID"]).flatMap(OperationID.init(wire:))
        let acceptedAt = (v?["acceptedAt"]?.intValue).map(Instant.init)
        // A committed rejection carries its typed error on the wire (contract
        // 3.4) - decode it rather than dropping it (the encode emits `rejection`).
        let rejection = v?["rejection"] == nil ? nil : decodeError(v?["rejection"])
        let committed = v?["committedThrough"] == nil ? nil : Cursor(
            storeEpoch: StoreEpoch(wire: string(v?["committedThrough"]?["storeEpoch"]) ?? "") ?? StoreEpoch(),
            sequence: Counter(v?["committedThrough"]?["sequence"]?.uintValue ?? 0))
        return CommandRecord(commandID: cmd, bodyDigest: digest, disposition: disp,
                             acceptedAt: acceptedAt, operationID: op, rejection: rejection,
                             committedThrough: committed)
    }

    private static func decodeQueryResult(_ v: JsonValue?) throws -> QueryResult? {
        let tag = string(v?["tag"]) ?? ""
        switch tag {
        case "nodeState":
            guard let d = try decodeDescriptor(v?["value"]) else { return nil }
            return .nodeState(d)
        case "identity":
            guard let r = try decodeIdentity(v?["value"]) else { return nil }
            return .identity(r)
        case "identities":
            let arr = v?["value"]?["items"]?.arrayValue ?? []
            var items: [IdentityRecord] = []
            for item in arr {
                if let r = try decodeIdentity(item) { items.append(r) }
            }
            return .identities(items)
        case "operation":
            guard let r = try decodeOperation(v?["value"]) else { return nil }
            return .operation(r)
        default: return nil
        }
    }

    private static func decodeIdentity(_ v: JsonValue?) throws -> IdentityRecord? {
        guard let id = IdentityID(wire: string(v?["id"]) ?? ""),
              let ihash = IdentityHash(hex: string(v?["identityHash"]) ?? ""),
              let dest = DestinationHash(hex: string(v?["deliveryDestination"]) ?? "") else { return nil }
        let name = string(v?["profile"]?["name"]) ?? ""
        return IdentityRecord(id: id, identityHash: ihash, deliveryDestination: dest,
                              profile: IdentityProfile(name: name),
                              revision: v?["revision"]?.uintValue ?? 0,
                              retired: v?["retired"]?.boolValue ?? false,
                              keyAvailable: v?["keyAvailable"]?.boolValue ?? false,
                              desiredEnabled: v?["desiredEnabled"]?.boolValue ?? false,
                              actualEnabled: v?["actualEnabled"]?.boolValue ?? false)
    }

    private static func decodeOperation(_ v: JsonValue?) throws -> OperationRecord? {
        guard let id = OperationID(wire: string(v?["id"]) ?? ""),
              let cmd = CommandID(wire: string(v?["commandID"]) ?? ""),
              let state = OperationRecord.State(rawValue: string(v?["state"]) ?? "") else { return nil }
        return OperationRecord(id: id, commandID: cmd, kind: string(v?["kind"]) ?? "",
                               state: state, createdAt: Instant(v?["createdAt"]?.intValue ?? 0),
                               finishedAt: (v?["finishedAt"]?.intValue).map(Instant.init))
    }

    private static func decodeActionResult(_ v: JsonValue?) throws -> ActionResult? {
        let tag = string(v?["tag"]) ?? ""
        switch tag {
        case "unit": return .unit
        case "identity":
            guard let r = try decodeIdentity(v?["value"]) else { return nil }
            return .identity(r)
        default: return nil
        }
    }

    private static func decodeError(_ v: JsonValue?) -> NodeError? {
        guard let code = NodeError.Code(rawValue: string(v?["code"]) ?? "") else { return nil }
        let retry = NodeError.Retry(rawValue: string(v?["retry"]) ?? "") ?? .never
        return NodeError(code: code, field: string(v?["field"]), retry: retry,
                         retryAfterMs: (v?["retryAfterMs"]?.uintValue).map(NonNegative.init),
                         message: string(v?["detail"]))
    }

    // MARK: - JSON helpers

    private static func jsonFrom(payload: Data) throws -> [String: JsonValue]? {
        // Use Foundation JSONSerialization (a JSON encoder is NOT the canonical
        // form - canonical is only for the staged body digest; control payloads
        // just need faithful decode).
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return obj.mapValues { JsonValue.fromAny($0) }
    }

    private static func string(_ v: JsonValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }
}

// MARK: - JsonValue Any bridge + accessors (decode side)

extension JsonValue {
    static func fromAny(_ any: Any) -> JsonValue {
        // Detect the concrete Foundation/CoreFoundation type BEFORE any Swift
        // casts: on Linux NSNumber and Bool cross-cast ambiguously
        // (NSNumber(1) as? Bool succeeds), so a Bool/NSNumber check ordered
        // before a type-ID check would mis-decode integers as booleans.
        let cf = any as AnyObject
        switch CFGetTypeID(cf) {
        case CFBooleanGetTypeID():
            return .boolean(cf as! Bool)
        case CFNumberGetTypeID():
            // A genuine CFNumber: render as its JCS decimal.
            let n = cf as! NSNumber
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 9.007199254740992e15 {
                return .number(String(Int64(d)))
            }
            return .number(String(d))
        case CFStringGetTypeID():
            return .string(cf as! String)
        default:
            break
        }
        if any is NSNull { return .null }
        if let arr = any as? [Any] { return .array(arr.map { fromAny($0) }) }
        if let dict = any as? [String: Any] { return .object(dict.mapValues { fromAny($0) }) }
        return .null
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .boolean(let b) = self { return b }; return nil }
    var uintValue: UInt64? { if case .number(let n) = self { return UInt64(n) }; return nil }
    var intValue: Int64? { if case .number(let n) = self { return Int64(n) }; return nil }
    var objectValue: [String: JsonValue]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JsonValue]? { if case .array(let a) = self { return a }; return nil }

    func asVersion() -> Version? {
        guard case let .object(o) = self else { return nil }
        guard let major = o["major"]?.uintValue, let minor = o["minor"]?.uintValue else { return nil }
        return Version(major: major, minor: minor)
    }
}
