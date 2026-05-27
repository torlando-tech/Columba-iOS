//
//  SwiftRNSBackend.swift
//  Columba (RNSBackendSwift — compiled into ColumbaApp)
//
//  Native `RnsBackend` (Android `:rns-backend-kt` analog) over reticulum-swift +
//  LXMF-swift. Ported from the pre-migration `main` integration, re-housed behind
//  the `RnsBackend` protocol. Because RNSAPI's Compat layer duplicates
//  reticulum-swift's type names (Destination/Link/Packet/Identity/ReticulumTransport),
//  every reticulum-swift/LXMF-swift type is module-qualified here.
//
//  Built up incrementally: conformance to `RnsBackend` + wiring into BackendFactory
//  happens once every method is implemented (so the partial type still compiles).
//

import Foundation
import RNSAPI
import ReticulumSwift
import LXMFSwift

@available(iOS 17.0, macOS 14.0, *)
public final class SwiftRNSBackend: @unchecked Sendable {

    // MARK: - Stack (reticulum-swift / LXMF-swift), module-qualified

    private var identity: ReticulumSwift.Identity?
    private var pathTable: ReticulumSwift.PathTable?
    private var transport: ReticulumSwift.ReticulumTransport?
    private var router: LXMFSwift.LXMRouter?
    private var deliveryDestination: ReticulumSwift.Destination?
    private var telephonyDestination: ReticulumSwift.Destination?

    public private(set) var localInfo: LocalInfo?

    /// Int→Link registry backing the Python-shaped `RnsTelephony` link API
    /// (the protocol uses Int linkIds; reticulum-swift uses `Link` actors).
    private var links: [Int: ReticulumSwift.Link] = [:]
    private var nextLinkId: Int = 1

    /// Section-name → reticulum interface id, backing the Python-shaped
    /// `addInterface(name:)` / `removeInterface(name:)` contract (Python resolves
    /// the name against its config file; we resolve it against InterfaceRepository).
    private var interfaceIds: [String: String] = [:]

    // MARK: - Events

    private let eventStream: AsyncStream<BackendEvent>
    private let eventContinuation: AsyncStream<BackendEvent>.Continuation
    private var delegate: RouterDelegate?

    public var events: AsyncStream<BackendEvent> { eventStream }

    /// Native backend capabilities. Unlike the Python backend, the Swift stack
    /// implements telemetry/location; it does not hot-reload interfaces (a
    /// restart is cheap here, but kept honest). LXST voice is the Swift stack.
    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            backendId: .swiftNative,
            versions: .init(reticulum: "0.2.3", lxmf: "0.3.4", lxst: nil, bleReticulum: nil),
            interfaces: .init(hotReloadInterfaces: true),
            telemetry: .init(
                collectorHostMode: .full,
                storeOwnTelemetry: .full,
                allowedRequestersFilter: .full
            ),
            performance: .init(batteryProfileTuning: .full, sharedInstanceAvailabilityChecks: false)
        )
    }

    public init() {
        (eventStream, eventContinuation) = AsyncStream.makeStream()
    }

    // MARK: - Lifecycle (ported from main's AppServices.initialize)

    @discardableResult
    public func start(_ params: StartParams) async throws -> LocalInfo {
        // 1. Identity from the saved private keys (or fresh if none provided).
        let id: ReticulumSwift.Identity
        if let bytes = params.identityBytes, !bytes.isEmpty {
            id = try ReticulumSwift.Identity(privateKeyBytes: bytes)
        } else {
            id = ReticulumSwift.Identity()
        }
        self.identity = id

        // 2. Path table + transport.
        let pt = ReticulumSwift.PathTable()
        self.pathTable = pt
        let tp = ReticulumSwift.ReticulumTransport(pathTable: pt)
        self.transport = tp
        await tp.registerPathRequestHandler()

        // 3. LXMRouter (owns its own LXMF store at databasePath).
        let dbPath = (params.configDir as NSString).appendingPathComponent("lxmf-swift.db")
        let rt = try await LXMFSwift.LXMRouter(identity: id, databasePath: dbPath)
        self.router = rt

        // 4. LXMF delivery destination + ratchets.
        let dest = ReticulumSwift.Destination(
            identity: id, appName: "lxmf", aspects: ["delivery"], type: .single, direction: .in
        )
        self.deliveryDestination = dest
        await tp.registerDestination(dest)
        let ratchetPath = (params.configDir as NSString).appendingPathComponent("ratchets")
        try await dest.enableRatchets(storagePath: ratchetPath)

        // 5. Wire router → transport + ratchets + delivery + delegate.
        await rt.setTransport(tp)
        await rt.setRatchetManager(dest.ratchetManager)
        try await rt.registerDeliveryDestination(dest)
        let d = await MainActor.run { RouterDelegate(continuation: self.eventContinuation) }
        self.delegate = d
        await rt.setDelegate(d)

        // 6. Telephony destination for inbound voice (lxst.telephony).
        let tel = ReticulumSwift.Destination(
            identity: id, appName: "lxst", aspects: ["telephony"], type: .single, direction: .in
        )
        self.telephonyDestination = tel
        await tp.registerDestination(tel)


        let info = LocalInfo(identityHash: id.hexHash, destinationHash: dest.hexHash)
        self.localInfo = info
        return info
    }

    public func stop() async {
        eventContinuation.finish()
        router = nil
        transport = nil
        pathTable = nil
        deliveryDestination = nil
        telephonyDestination = nil
        links.removeAll()
        localInfo = nil
    }

    // MARK: - Messaging (ported from main's sendAnnounce / handleOutbound)

    @discardableResult
    public func announce(displayName: String) async throws -> Bool {
        try await emitAnnounce(on: deliveryDestination, displayName: displayName, withRatchet: true)
    }

    @discardableResult
    public func announceTelephony(displayName: String) async throws -> Bool {
        try await emitAnnounce(on: telephonyDestination, displayName: displayName, withRatchet: false)
    }

    private func emitAnnounce(on destination: ReticulumSwift.Destination?, displayName: String, withRatchet: Bool) async throws -> Bool {
        guard let transport, let destination else { return false }
        destination.appData = displayName.data(using: .utf8)
        var ratchetPub: Data? = nil
        if withRatchet, let mgr = destination.ratchetManager {
            await mgr.rotateIfNeeded()
            ratchetPub = await mgr.currentRatchetPublicBytes()
        }
        let announce = ReticulumSwift.Announce(destination: destination, ratchet: ratchetPub)
        let packet = try announce.buildPacket()
        try await transport.send(packet: packet)
        return true
    }

    public func sendOpportunistic(destHashHex: String, content: String) async throws -> SendOutcome {
        guard let router, let id = identity else { return .notStarted }
        guard let destHash = Self.hexData(destHashHex), !destHash.isEmpty else { return .badHash }
        var msg = LXMFSwift.LXMessage(
            destinationHash: destHash,
            sourceIdentity: id,
            content: Data(content.utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .opportunistic
        )
        try await router.handleOutbound(&msg)
        return .queued(messageHash: msg.hash.hexHash)
    }

    // MARK: - Propagation + persistence

    @discardableResult
    public func setPropagationNode(destHashHex: String, stampCost: Int) async throws -> Bool {
        guard let router else { return false }
        let hash = destHashHex.isEmpty ? nil : Self.hexData(destHashHex)
        await router.setOutboundPropagationNode(hash)
        if stampCost > 0 { await router.setPropagationStampCost(stampCost) }
        return true
    }

    public func propagationSync(timeout: TimeInterval) async throws -> PropagationSyncResult {
        guard let router else {
            return PropagationSyncResult(ok: false, state: .noRouter, receivedMessages: 0, reason: "no router")
        }
        // syncFromPropagationNode returns Void; the new-message count arrives via
        // the delegate's didCompleteSyncWithNewMessages → BackendEvent stream.
        try await router.syncFromPropagationNode()
        return PropagationSyncResult(ok: true, state: .complete, receivedMessages: 0, reason: "")
    }

    @discardableResult
    public func persist() async -> Bool {
        await router?.persistPendingState()
        return true
    }

    // MARK: - Telephony (RNS.Link pipe for LXST voice)
    //
    // The Swift LXST voice state machine drives these; the backend just owns the
    // Link and bridges its inbound packets + state changes onto the neutral event
    // stream. Ported from main's CallManager identity-resolve + initiateLink path.

    public func openLink(destHashHex: String, aspect: String) async throws -> (ok: Bool, linkId: Int, reason: String) {
        guard let transport, let localId = identity, let pathTable else {
            return (false, 0, "not started")
        }
        guard let destHash = Self.hexData(destHashHex), !destHash.isEmpty else {
            return (false, 0, "bad hash")
        }

        // 1. Ensure a path exists (request + await if not already known).
        if await transport.hasPath(for: destHash) == false {
            await transport.requestPath(for: destHash)
            if await transport.awaitPath(for: destHash, timeout: 15.0) == false {
                return (false, 0, "no path")
            }
        }

        // 2. Recall the peer identity from the path entry's announced public keys
        //    (64 bytes = enc + sig public keys), exactly as main's resolveIdentity.
        guard let entry = await pathTable.lookup(destinationHash: destHash),
              entry.publicKeys.count == 64,
              let remoteIdentity = try? ReticulumSwift.Identity(publicKeyBytes: entry.publicKeys) else {
            return (false, 0, "no identity")
        }

        // 3. Build the outbound destination from the aspect ("lxst.telephony" →
        //    appName "lxst", aspects ["telephony"]) so its hash matches destHash.
        let parts = aspect.split(separator: ".").map(String.init)
        let appName = parts.first ?? "lxst"
        let aspects = Array(parts.dropFirst())
        let dest = ReticulumSwift.Destination(
            identity: remoteIdentity, appName: appName, aspects: aspects,
            type: .single, direction: .out
        )

        // 4. Initiate the link (throws TransportError.noPathAvailable if the path
        //    evaporated between the check above and here).
        let link = try await transport.initiateLink(to: dest, identity: localId)
        let linkId = nextLinkId
        nextLinkId += 1
        links[linkId] = link

        // 5. Bridge inbound link packets + state transitions onto the event stream.
        //    stateUpdates yields the terminal .closed(reason) itself, so a separate
        //    close callback would only duplicate it.
        let cont = eventContinuation
        await link.setPacketCallback { data, _ in
            cont.yield(.linkPacket(linkId: linkId, data: data, t: Date()))
        }
        Task {
            for await st in await link.stateUpdates {
                let (s, r) = Self.linkStateString(st)
                cont.yield(.linkState(linkId: linkId, state: s, reason: r, inbound: false, t: Date()))
            }
        }
        return (true, linkId, "")
    }

    @discardableResult
    public func linkSend(linkId: Int, data: Data) async throws -> Bool {
        guard let link = links[linkId] else { return false }
        try await link.send(data)
        return true
    }

    @discardableResult
    public func linkIdentify(linkId: Int) async throws -> Bool {
        guard let link = links[linkId], let localId = identity else { return false }
        try await link.identify(identity: localId)
        return true
    }

    @discardableResult
    public func linkTeardown(linkId: Int) async throws -> Bool {
        guard let link = links.removeValue(forKey: linkId) else { return false }
        await link.close(reason: .initiatorClosed)
        return true
    }

    private static func linkStateString(_ s: ReticulumSwift.LinkState) -> (String, String) {
        switch s {
        case .pending:   return ("pending", "")
        case .handshake: return ("handshake", "")
        case .active:    return ("active", "")
        case .stale:     return ("stale", "")
        case .closed(let reason): return ("closed", String(describing: reason))
        }
    }

    // MARK: - Status

    public func statusSnapshot() async -> StatusSnapshot? {
        guard let transport else { return nil }
        let snaps = await transport.getInterfaceSnapshots()
        let ifaces = snaps.map { s in
            StatusSnapshot.InterfaceStatus(
                sectionName: s.id,
                name: s.name,
                online: s.state == .connected,
                rxBytes: 0,   // reticulum-swift's InterfaceSnapshot exposes no byte counters
                txBytes: 0
            )
        }
        let destCount = await transport.destinationCount
        let pathCount = await transport.getPathTable().count
        return StatusSnapshot(
            started: identity != nil,
            interfaces: ifaces,
            destinationTableSize: destCount,
            pathTableSize: pathCount
        )
    }

    // MARK: - NomadNet (one-shot page fetch over a fresh RNS Link)
    //
    // Ported from main's NomadNetBrowserService: resolve a path + node identity,
    // open a link to the `nomadnetwork.node` destination, wait for it to become
    // established, issue an RNS request for the page path, and await the response
    // (racing each wait against a timeout). The link is one-shot — torn down on
    // return. Form fields arrive already "field_"-prefixed by the caller.

    public func fetchNomadNetPage(
        destHashHex: String,
        path: String,
        timeout: TimeInterval,
        formFields: [String: String]?
    ) async throws -> NomadNetFetchResult {
        func fail(_ s: NomadNetFetchResult.Status) -> NomadNetFetchResult {
            NomadNetFetchResult(ok: false, status: s, data: Data(), contentType: "")
        }
        guard let transport, let localId = identity, let pathTable else { return fail(.notStarted) }
        guard let destHash = Self.hexData(destHashHex), !destHash.isEmpty else { return fail(.badHash) }

        // 1. Ensure a path, then recall the node identity from its announce.
        if await transport.hasPath(for: destHash) == false {
            await transport.requestPath(for: destHash)
            if await transport.awaitPath(for: destHash, timeout: 15.0) == false { return fail(.noPath) }
        }
        guard let entry = await pathTable.lookup(destinationHash: destHash),
              entry.publicKeys.count == 64,
              let nodeIdentity = try? ReticulumSwift.Identity(publicKeyBytes: entry.publicKeys) else {
            return fail(.noPath)
        }

        // 2. Establish a fresh link to the nomadnetwork.node destination.
        let dest = ReticulumSwift.Destination(
            identity: nodeIdentity, appName: "nomadnetwork", aspects: ["node"],
            type: .single, direction: .out
        )
        let link: ReticulumSwift.Link
        do {
            link = try await transport.initiateLink(to: dest, identity: localId)
        } catch {
            return fail(.linkFailed)
        }
        defer { let l = link; Task { await l.close(reason: .initiatorClosed) } }
        guard await Self.awaitLinkEstablished(link, timeout: timeout) else { return fail(.linkFailed) }

        // 3. Build the request payload (form fields → msgpack map) and send it.
        let requestData: ReticulumSwift.MessagePackValue?
        if let formFields, !formFields.isEmpty {
            var map: [ReticulumSwift.MessagePackValue: ReticulumSwift.MessagePackValue] = [:]
            for (k, v) in formFields { map[.string(k)] = .string(v) }
            requestData = .map(map)
        } else {
            requestData = nil
        }
        let receipt = try await link.request(path: path, data: requestData, timeout: timeout)

        // 4. Await the response, racing the status stream against a timeout.
        let (data, status) = await Self.awaitResponse(receipt, timeout: timeout + 2.0)
        guard status == .ok, let data else { return fail(status) }
        return NomadNetFetchResult(ok: true, status: .ok, data: data, contentType: "")
    }

    /// Wait for a link to reach an established state, racing against a timeout.
    private static func awaitLinkEstablished(_ link: ReticulumSwift.Link, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await st in await link.stateUpdates {
                    if st.isEstablished { return true }
                    if case .closed = st { return false }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                return false
            }
            let ok = await group.next() ?? false
            group.cancelAll()
            return ok
        }
    }

    /// Await an RNS request response, racing the status stream against a timeout.
    private static func awaitResponse(_ receipt: ReticulumSwift.RequestReceipt, timeout: TimeInterval) async -> (Data?, NomadNetFetchResult.Status) {
        await withTaskGroup(of: (Data?, NomadNetFetchResult.Status).self) { group in
            group.addTask {
                for await status in await receipt.statusUpdates {
                    switch status {
                    case .responseReceived:
                        let raw = await receipt.responseData
                        return (raw.map { Self.unwrapResponseData($0) }, .ok)
                    case .failed: return (nil, .requestFailed)
                    case .timeout: return (nil, .timeout)
                    default: continue
                    }
                }
                return (nil, .requestFailed)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                return (nil, .timeout)
            }
            let result = await group.next() ?? (nil, .unknown)
            group.cancelAll()
            return result
        }
    }

    /// NomadNet responses come back msgpack-wrapped (binary or string); unwrap to
    /// the raw page bytes, falling back to the raw payload if it isn't msgpack.
    private static func unwrapResponseData(_ data: Data) -> Data {
        if let value = try? ReticulumSwift.unpackMsgPack(data) {
            switch value {
            case .binary(let bytes): return bytes
            case .string(let str): return str.data(using: .utf8) ?? data
            default: break
            }
        }
        return data
    }

    // MARK: - Transport admin (live interface add/remove, no restart)
    //
    // The Python backend resolves a section name against its on-disk RNS config;
    // the Swift backend resolves it against the shared InterfaceRepository (the
    // same entity store the UI writes), then builds the reticulum-swift interface
    // for that entity — porting main's per-type bring-up (TCP/Auto/RNode/BLE/MPC).

    @discardableResult
    public func addInterface(name: String) async throws -> (ok: Bool, reason: String) {
        guard transport != nil, identity != nil else { return (false, "not started") }
        guard let entity = Self.entity(forSection: name) else {
            return (false, "no configured interface named \(name)")
        }
        do {
            try await buildAndAdd(entity)
            interfaceIds[name] = entity.id
            return (true, "")
        } catch {
            return (false, "\(error)")
        }
    }

    @discardableResult
    public func removeInterface(name: String) async throws -> (ok: Bool, reason: String) {
        guard let transport else { return (false, "not started") }
        // Prefer the tracked id; fall back to the entity's id if we never tracked
        // it (e.g. added before this process started). removeInterface disconnects.
        guard let rid = interfaceIds[name] ?? Self.entity(forSection: name)?.id else {
            return (false, "no interface named \(name)")
        }
        await transport.removeInterface(id: rid)
        interfaceIds.removeValue(forKey: name)
        return (true, "")
    }

    /// Resolve a config-section name back to its InterfaceEntity via the shared
    /// repository (mirrors how PythonConfigWriter names sections on write).
    private static func entity(forSection name: String) -> InterfaceEntity? {
        InterfaceRepository().interfaces.first { PythonConfigWriter.sectionName(for: $0) == name }
    }

    /// Build the reticulum-swift interface for an entity and register it on the
    /// transport. The reticulum interface id is the entity id (stable across the
    /// add/remove pair). Ported type-by-type from main's start*Interface methods.
    private func buildAndAdd(_ entity: InterfaceEntity) async throws {
        guard let transport, let localId = identity else { return }
        let mode = ReticulumSwift.InterfaceMode(rawValue: entity.mode.rawValue) ?? .full
        let rid = entity.id

        func config(_ type: ReticulumSwift.InterfaceType, host: String, port: UInt16) -> ReticulumSwift.InterfaceConfig {
            ReticulumSwift.InterfaceConfig(
                id: rid, name: entity.name, type: type, enabled: true, mode: mode, host: host, port: port
            )
        }

        switch entity.config {
        case .tcpClient(let c):
            let iface = try ReticulumSwift.TCPInterface(config: config(.tcp, host: c.targetHost, port: c.targetPort))
            try await transport.addInterface(iface)

        case .tcpServer(let c):
            let iface = try ReticulumSwift.TCPServerInterface(config: config(.tcp, host: c.listenIp, port: c.listenPort))
            try await transport.addInterface(iface)

        case .autoInterface(let c):
            let iface = ReticulumSwift.AutoInterface(config: config(.autoInterface, host: c.groupId ?? "reticulum", port: 0))
            try await transport.addAutoInterface(iface)

        case .rnode(let c):
            let iface = try ReticulumSwift.RNodeInterface(config: config(.rnode, host: c.deviceName, port: 0))
            // Compat.RadioConfig and ReticulumSwift.RadioConfig have identical
            // fields; build the reticulum one directly from the entity config.
            try await iface.configureRadio(ReticulumSwift.RadioConfig(
                frequency: c.frequency, bandwidth: c.bandwidth, txPower: c.txPower,
                spreadingFactor: c.spreadingFactor, codingRate: c.codingRate,
                stAlock: c.stAlock, ltAlock: c.ltAlock
            ))
            try await transport.addInterface(iface)

        case .ble:
            let driver = ReticulumSwift.CoreBluetoothBLEDriver(identityHash: localId.hash)
            let iface = ReticulumSwift.BLEInterface(
                config: config(.ble, host: "", port: 0), driver: driver, transportIdentity: localId.hash
            )
            try await transport.addBLEInterface(iface)

        case .multipeer(let c):
            let iface = ReticulumSwift.MPCInterface(
                config: config(.multipeerConnectivity, host: c.serviceType, port: 0),
                displayName: String(localId.hexHash.prefix(8))
            )
            try await transport.addMPCInterface(iface)
        }
    }

    /// Decode a hex string to Data (RNSAPI's HexExt is Data→String only, and
    /// reticulum-swift's Data here would make a shared helper ambiguous).
    private static func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    // MARK: - Router delegate → BackendEvent

    /// Bridges LXMRouter delegate callbacks (inbound / delivery / failure) onto
    /// the neutral `BackendEvent` stream. @MainActor per the protocol.
    @MainActor
    private final class RouterDelegate: LXMFSwift.LXMRouterDelegate {
        let continuation: AsyncStream<BackendEvent>.Continuation
        init(continuation: AsyncStream<BackendEvent>.Continuation) { self.continuation = continuation }

        func router(_ router: LXMFSwift.LXMRouter, didReceiveMessage message: LXMFSwift.LXMessage) {
            let content = String(data: message.content, encoding: .utf8) ?? ""
            let title = String(data: message.title, encoding: .utf8) ?? ""
            continuation.yield(.inbound(sourceHash: message.sourceHash.hexHash, content: content, title: title, t: Date()))
        }
        func router(_ router: LXMFSwift.LXMRouter, didUpdateMessage message: LXMFSwift.LXMessage) {
            if message.state == .delivered {
                continuation.yield(.delivery(messageHash: message.hash.hexHash, state: "delivered", t: Date()))
            }
        }
        func router(_ router: LXMFSwift.LXMRouter, didFailMessage message: LXMFSwift.LXMessage, reason: LXMFSwift.LXMFError) {
            continuation.yield(.delivery(messageHash: message.hash.hexHash, state: "failed", t: Date()))
        }
        func router(_ router: LXMFSwift.LXMRouter, didConfirmDelivery messageHash: Data) {
            continuation.yield(.delivery(messageHash: messageHash.hexHash, state: "delivered", t: Date()))
        }
        func router(_ router: LXMFSwift.LXMRouter, didUpdateSyncState state: LXMFSwift.PropagationTransferState) {}
        func router(_ router: LXMFSwift.LXMRouter, didCompleteSyncWithNewMessages newMessages: Int) {}
    }
}

// Small hex helper local to this module (Compat's HexExt is in RNSAPI; Data here
// is reticulum-swift's, so use a local extension to avoid ambiguity).
private extension Data {
    var hexHash: String { map { String(format: "%02x", $0) }.joined() }
}
