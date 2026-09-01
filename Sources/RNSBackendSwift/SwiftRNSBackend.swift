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
import os
import RNSAPI
import ReticulumSwift
import LXMFSwift

@available(iOS 17.0, macOS 14.0, *)
public final class SwiftRNSBackend: RnsBackend, @unchecked Sendable {

    private static let log = Logger(subsystem: "network.columba.Columba", category: "SwiftRNSBackend")

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
    /// The fire-and-forget Task draining each link's `stateUpdates`, keyed by
    /// linkId. Tracked so it can be cancelled on linkTeardown/stop — otherwise
    /// it keeps a strong capture of the (kept-open) eventContinuation and yields
    /// stale linkState events into the next session after a restart.
    private var linkStateTasks: [Int: Task<Void, Never>] = [:]
    private var nextLinkId: Int = 1
    /// Serializes the mutable registries that async methods touch from
    /// different tasks: `nextLinkId`, `links`, `linkStateTasks`, and
    /// `interfaceIds`. SwiftRNSBackend is a class (not an actor) so `linkSend`
    /// stays hop-free on the audio path; without this lock, concurrent
    /// `openLink` callers race the `nextLinkId` increment + dictionary writes
    /// (two callers grab the same id, the second orphans the first link), and
    /// `statusSnapshot()` can read `interfaceIds` while `start()`/`addInterface`
    /// mutate it (Swift Dictionary read+write races are UB → release-build
    /// crashes). Mirrors the Python backend's `_link_id_lock`. A Dictionary is
    /// a value type, so snapshotting one under the lock (`let copy = dict`) is
    /// a cheap COW retain. Never held across an `await`.
    private let linkLock = NSLock()

    /// Section-name → reticulum interface id, backing the Python-shaped
    /// `addInterface(name:)` / `removeInterface(name:)` contract (Python resolves
    /// the name against its config file; we resolve it against InterfaceRepository).
    private var interfaceIds: [String: String] = [:]

    // MARK: - Events

    private let eventStream: AsyncStream<BackendEvent>
    private let eventContinuation: AsyncStream<BackendEvent>.Continuation
    private var delegate: RouterDelegate?

    /// Polls the path table for received announces and bridges them onto the
    /// event stream as `.announce`. reticulum-swift exposes no announce callback —
    /// the path table IS the announce record (the UI's announces tab reads it the
    /// same way), so we diff it on a short cadence, mirroring the Python backend's
    /// periodic drain.
    private var announcePoller: Task<Void, Never>?

    public var events: AsyncStream<BackendEvent> { eventStream }

    /// Native backend capabilities. The Swift stack hot-reloads interfaces (live
    /// add/remove via RnsTransportAdmin, no restart). Telemetry caps are honest-
    /// unsupported for now: `RnsTelemetry.sendLocationTelemetry` is wired and
    /// Sideband-compatible, but collector-host mode isn't implemented and the app
    /// location feature is gated off — flip to `.full` once those land. Battery-
    /// profile tuning hooks aren't implemented on this stack either.
    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            backendId: .swiftNative,
            versions: .init(reticulum: "0.2.3", lxmf: "0.3.4", lxst: nil, bleReticulum: nil),
            interfaces: .init(hotReloadInterfaces: true),
            telemetry: .init(
                collectorHostMode: .unsupported,
                storeOwnTelemetry: .unsupported,
                allowedRequestersFilter: .unsupported,
                degradationHint: "Telemetry send is wired (Sideband-compatible FIELD_TELEMETRY 0x02); collector-host mode isn't implemented and the app location feature is currently gated off."
            ),
            performance: .init(batteryProfileTuning: .unsupported, sharedInstanceAvailabilityChecks: false)
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

        // 6.5. Bring up the enabled interfaces on THIS backend's transport.
        //
        // The Python backend loads its interfaces from the RNS config file when
        // `start()` runs `RNS.Reticulum(config_dir)`; the Swift backend has no
        // such config file, so without this its transport would have zero
        // interfaces and nothing would connect (the "connecting forever" bug —
        // the legacy `AppServices.connectTCPInterface` startup path added them to
        // a separate, pre-dual-backend reticulum-swift stack, never to this
        // backend). Reuses the same per-type `buildAndAdd` that the hot-reload
        // `addInterface(name:)` path uses, so startup and live edits share one
        // path. Per-interface failures are non-fatal — one bad interface must not
        // block the rest or the whole start.
        for entity in InterfaceRepository().interfaces where entity.enabled {
            let section = PythonConfigWriter.sectionName(for: entity)
            do {
                try await buildAndAdd(entity)
                linkLock.lock()
                interfaceIds[section] = entity.id
                linkLock.unlock()
            } catch {
                Self.log.error("start: interface \(section, privacy: .public) bring-up failed: \(String(describing: error), privacy: .public)")
            }
        }

        // 7. Start bridging received announces (path-table diff) onto events.
        startAnnouncePolling()

        let info = LocalInfo(identityHash: id.hexHash, destinationHash: dest.hexHash)
        self.localInfo = info
        return info
    }

    public func stop() async {
        announcePoller?.cancel()
        announcePoller = nil
        // Do NOT finish the continuation here: the stream is created once in
        // init and must survive stop/start cycles (backend restart, identity
        // switch). Finishing it permanently terminates the AsyncStream, so a
        // later start() on the same instance would silently drop every event.
        // PythonRNSBackend keeps its continuation open across stop() for the
        // same reason.
        router = nil
        transport = nil
        pathTable = nil
        deliveryDestination = nil
        telephonyDestination = nil
        // Cancel the per-link stateUpdates drain tasks before dropping the
        // links — otherwise they outlive stop() and keep yielding stale
        // linkState events into the (deliberately kept-open) continuation.
        linkLock.lock()
        linkStateTasks.values.forEach { $0.cancel() }
        linkStateTasks.removeAll()
        links.removeAll()
        linkLock.unlock()
        localInfo = nil
    }

    /// Diff the path table on a short cadence, emitting `.announce` for each
    /// newly-seen or freshly re-announced known destination (lxmf.delivery /
    /// lxmf.propagation / lxst.telephony / nomadnetwork.node). `lastSeen` is
    /// task-local, so no shared mutable state escapes the poller.
    private func startAnnouncePolling() {
        // Cancel any prior poller first: start() has no idempotency guard, so a
        // second start() without an intervening stop() would otherwise leak the
        // old task (still polling the orphaned PathTable it captured) and yield
        // every announce twice.
        announcePoller?.cancel()
        guard let pathTable else { return }
        let cont = eventContinuation
        announcePoller = Task {
            var lastSeen: [String: Date] = [:]
            while !Task.isCancelled {
                for entry in await pathTable.allEntries() {
                    guard let aspect = entry.detectedAspect else { continue }
                    let hash = entry.destinationHash.hexHash
                    if let prev = lastSeen[hash], prev >= entry.timestamp { continue }
                    lastSeen[hash] = entry.timestamp
                    cont.yield(.announce(
                        destHash: hash,
                        appDataHex: (entry.appData ?? Data()).hexHash,
                        aspect: aspect,
                        publicKeysHex: entry.publicKeys.hexHash,
                        interfaceName: entry.interfaceId,
                        hops: Int(entry.hopCount),
                        t: entry.timestamp
                    ))
                }
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            }
        }
    }

    // MARK: - Messaging (ported from main's sendAnnounce / handleOutbound)

    @discardableResult
    public func announce(displayName: String) async throws -> Bool {
        // Canonical LXMF (>= 0.5.0) delivery-announce app_data:
        // msgpack([display_name_utf8_bytes, stamp_cost]). Mirrors LXMF
        // LXMRouter.get_announce_app_data (what the Python backend and Sideband
        // emit) so peers decode the name via the msgpack path rather than
        // relying on LXMF's legacy raw-utf8 fallback (which also drops the
        // stamp cost). stamp_cost is nil — Columba registers its delivery
        // identity without an inbound stamp requirement, matching the Python
        // backend's register_delivery_identity(display_name=…).
        let appData = packMsgPack(.array([.binary(Data(displayName.utf8)), .null]))
        return try await emitAnnounce(on: deliveryDestination, appData: appData, withRatchet: true)
    }

    @discardableResult
    public func announceTelephony(displayName: String) async throws -> Bool {
        // The lxst.telephony announce app_data is LXST's, not LXMF's — keep the
        // raw display-name bytes the Telephone layer expects.
        try await emitAnnounce(on: telephonyDestination, appData: Data(displayName.utf8), withRatchet: false)
    }

    private func emitAnnounce(on destination: ReticulumSwift.Destination?, appData: Data, withRatchet: Bool) async throws -> Bool {
        guard let transport, let destination else { return false }
        destination.appData = appData
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

    @discardableResult
    public func sendLxmfMessage(
        destHashHex: String,
        content: String,
        method: RNSAPI.LXDeliveryMethod,
        imageData: Data?,
        imageFormat: String?,
        fileAttachments: [RnsFileAttachment]?,
        audioAttachment: RnsAudio?,
        iconAppearance: RNSAPI.IconAppearance?,
        replyToMessageHashHex: String?,
        replyQuotedContent: String?,
        extraFields: [UInt8: Data]?
    ) async throws -> SendOutcome {
        guard let router, let id = identity else { return .notStarted }
        guard let destHash = Self.hexData(destHashHex), !destHash.isEmpty else { return .badHash }

        // Build the canonical on-wire LXMF field map (shared with PythonRNSBackend
        // so both backends encode identically). LXMessage.fields is [UInt8: Any].
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: imageData, imageFormat: imageFormat,
            fileAttachments: fileAttachments, audioAttachment: audioAttachment, iconAppearance: iconAppearance,
            replyToMessageHashHex: replyToMessageHashHex, replyQuotedContent: replyQuotedContent,
            extraFields: extraFields)

        var msg = LXMFSwift.LXMessage(
            destinationHash: destHash,
            sourceIdentity: id,
            content: Data(content.utf8),
            title: Data(),
            fields: fields.isEmpty ? nil : fields,
            desiredMethod: Self.lxmfMethod(method)
        )
        try await router.handleOutbound(&msg)
        return .queued(messageHash: msg.hash.hexHash)
    }

    @discardableResult
    public func sendReaction(destHashHex: String, targetMessageHashHex: String, emoji: String) async throws -> SendOutcome {
        guard let router, let id = identity else { return .notStarted }
        guard let destHash = Self.hexData(destHashHex), !destHash.isEmpty,
              let targetHash = Self.hexData(targetMessageHashHex) else { return .badHash }
        // Canonical FIELD_REACTION (0x40): {0x00: targetHashBytes, 0x01: emojiUTF8}.
        let reaction: [UInt8: Any] = [
            LxmfFields.REACTION_TO: targetHash,
            LxmfFields.REACTION_CONTENT: Data(emoji.utf8),
        ]
        var msg = LXMFSwift.LXMessage(
            destinationHash: destHash,
            sourceIdentity: id,
            content: Data(),
            title: Data(),
            fields: [LxmfFields.FIELD_REACTION: reaction],
            desiredMethod: .opportunistic
        )
        try await router.handleOutbound(&msg)
        return .queued(messageHash: msg.hash.hexHash)
    }

    private static func lxmfMethod(_ m: RNSAPI.LXDeliveryMethod) -> LXMFSwift.LXDeliveryMethod {
        switch m {
        case .direct: return .direct
        case .propagated: return .propagated
        default: return .opportunistic
        }
    }

    // MARK: - Telemetry (RnsTelemetry)
    //
    // Location payloads are Sideband-`Telemeter`-packed by the caller (LXMF-swift's
    // Telemetry codec is Sideband-compatible) and carried under FIELD_TELEMETRY
    // (0x02); cease/extras ride FIELD_CUSTOM_META (0xFD). Collector-host mode isn't
    // implemented on the Swift backend yet — the capability declares it unsupported.

    @discardableResult
    public func sendLocationTelemetry(destHashHex: String, packed: Data, customMeta: Data?) async throws -> SendOutcome {
        var extra: [UInt8: Data] = [LxmfFields.FIELD_TELEMETRY: packed]
        if let customMeta { extra[LxmfFields.FIELD_CUSTOM_META] = customMeta }
        return try await sendLxmfMessage(
            destHashHex: destHashHex, content: "", method: .opportunistic,
            imageData: nil, imageFormat: nil, fileAttachments: nil,
            audioAttachment: nil, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil, extraFields: extra
        )
    }

    // A "cease" (stop sharing) is just sendLocationTelemetry with a zeroed
    // Telemeter body + msgpack {"cease":true} meta (see CeaseTelemetry) — no
    // dedicated method, matching Android Columba's seam.

    public func setTelemetryCollectorMode(enabled: Bool) async -> Bool { false }
    public func storeOwnTelemetry(packed: Data) async -> Bool { false }
    public func setTelemetryAllowedRequesters(_ allowedHashesHex: Set<String>) async -> Bool { false }

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
        // syncFromPropagationNode() returns Void, but the router's syncState
        // carries the count of messages pulled this sync (receivedMessages is
        // incremented per message as they're retrieved). Read it after the
        // await rather than hardcoding 0, so the UI's "N new messages" is real.
        //
        // The router applies only per-request timeouts internally — it has no
        // overall deadline, so a stalled link or a missing response would block
        // the caller forever. Bound the whole sync by the caller's `timeout` by
        // racing it against a sleep; whichever finishes first wins and the
        // loser is cancelled.
        let timedOut = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await router.syncFromPropagationNode()
                return false
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return true
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        let received = await router.syncState.receivedMessages
        if timedOut {
            return PropagationSyncResult(ok: false, state: .transferFailed, receivedMessages: received, reason: "timeout")
        }
        return PropagationSyncResult(ok: true, state: .complete, receivedMessages: received, reason: "")
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

    public func openLink(destHashHex: String, aspect: String, identityPublicKeyHex: String?) async throws -> (ok: Bool, linkId: Int, reason: String) {
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
        let cont = eventContinuation
        // Reserve the id and register BOTH the link and its stateUpdates drain
        // task in one critical section. If these were split (task stored after
        // the setPacketCallback await), a stop() racing that window would clear
        // the maps in between and then openLink would re-insert an orphaned
        // task into the freshly-emptied linkStateTasks — keeping the link actor
        // alive and yielding stale events into the next session until the next
        // stop(). The Task constructor is synchronous (its awaits run later), so
        // it's safe to build under the lock; nothing in the task body touches
        // linkLock, so there's no re-entrancy.
        linkLock.lock()
        let linkId = nextLinkId
        nextLinkId += 1
        links[linkId] = link
        linkStateTasks[linkId] = Task {
            for await st in await link.stateUpdates {
                let (s, r) = Self.linkStateString(st)
                cont.yield(.linkState(linkId: linkId, state: s, reason: r, inbound: false, t: Date()))
            }
        }
        linkLock.unlock()

        // 5. Bridge inbound link packets onto the event stream. stateUpdates
        //    (drained above) yields the terminal .closed(reason) itself, so a
        //    separate close callback would only duplicate it.
        await link.setPacketCallback { data, _ in
            cont.yield(.linkPacket(linkId: linkId, data: data, t: Date()))
        }
        return (true, linkId, "")
    }

    @discardableResult
    public func linkSend(linkId: Int, data: Data) async throws -> Bool {
        linkLock.lock()
        let link = links[linkId]
        linkLock.unlock()
        guard let link else { return false }
        try await link.send(data)
        return true
    }

    @discardableResult
    public func linkIdentify(linkId: Int) async throws -> Bool {
        linkLock.lock()
        let link = links[linkId]
        linkLock.unlock()
        guard let link, let localId = identity else { return false }
        try await link.identify(identity: localId)
        return true
    }

    @discardableResult
    public func linkTeardown(linkId: Int) async throws -> Bool {
        linkLock.lock()
        linkStateTasks.removeValue(forKey: linkId)?.cancel()
        let link = links.removeValue(forKey: linkId)
        linkLock.unlock()
        guard let link else { return false }
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
        // Snapshot interfaceIds under the lock (cheap COW copy) so the map below
        // can't race a concurrent start()/addInterface()/removeInterface() write.
        linkLock.lock()
        let interfaceIdsSnapshot = interfaceIds
        linkLock.unlock()
        let ifaces = snaps.map { s in
            // Report the config *section name* (what AppServices matches against
            // via PythonConfigWriter.sectionName), NOT the raw reticulum interface
            // id. The reticulum id is the entity UUID (buildAndAdd uses it as the
            // interface id), so reverse-map it through `interfaceIds`
            // (section -> entity.id). Without this, AppServices.applyPythonInterfaceStatus
            // never matches a Swift-backend interface to its entity, so the UI's
            // connection badge stays "disconnected" even when the interface is up.
            let section = interfaceIdsSnapshot.first(where: { $0.value == s.id })?.key ?? s.id
            return StatusSnapshot.InterfaceStatus(
                sectionName: section,
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

    /// The destinations this backend registered on its transport in `start()`:
    /// the `lxmf.delivery` destination and the `lxst.telephony` destination.
    /// Both `hexHash` values are lowercase hex (reticulum-swift `%02x`). Empty
    /// before `start` (both are nil). Mirrors what the Python backend reports so
    /// the NE's sniff-only filter matches the same set in either backend.
    public func registeredDestinationHashes() async -> [String] {
        [deliveryDestination, telephonyDestination].compactMap { $0?.hexHash }
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

        // The link/fetch algorithm is shared with the Network Extension node
        // (Model B) via `NomadNetFetch` so both stacks behave identically.
        let r = try await NomadNetFetch.fetch(
            transport: transport, identity: localId, pathTable: pathTable,
            destHash: destHash, path: path, timeout: timeout, formFields: formFields
        )
        return NomadNetFetchResult(
            ok: r.ok,
            status: NomadNetFetchResult.Status(rawValue: r.status.rawValue) ?? .unknown,
            data: r.data, contentType: r.contentType
        )
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
        // Idempotent: start() already brings up enabled interfaces, and the
        // apply/hot-reload path may re-request one — don't add it twice.
        linkLock.lock()
        let alreadyAdded = interfaceIds[name] != nil
        linkLock.unlock()
        if alreadyAdded { return (true, "already added") }
        guard let entity = Self.entity(forSection: name) else {
            return (false, "no configured interface named \(name)")
        }
        do {
            try await buildAndAdd(entity)
            linkLock.lock()
            interfaceIds[name] = entity.id
            linkLock.unlock()
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
        linkLock.lock()
        let tracked = interfaceIds[name]
        linkLock.unlock()
        guard let rid = tracked ?? Self.entity(forSection: name)?.id else {
            return (false, "no interface named \(name)")
        }
        await transport.removeInterface(id: rid)
        linkLock.lock()
        interfaceIds.removeValue(forKey: name)
        linkLock.unlock()
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
            let fieldsPacked = (message.fields?.isEmpty == false) ? LxmfFieldCodec.pack(message.fields!) : Data()
            // The Swift/NE backend persists inbound through its own LXMRouter
            // (GRDB) and has no receiving-interface RSSI/SNR to attach — the
            // signal metrics are a Python-backend concern (captured at delivery
            // time in rns_bridge.py). Pass nil; the cards stay hidden.
            continuation.yield(.inbound(sourceHash: message.sourceHash.hexHash, messageHash: message.hash.hexHash, content: content, title: title, fieldsPacked: fieldsPacked, method: Self.mapDeliveryMethod(message.method), rssi: nil, snr: nil, t: Date()))
        }
        func router(_ router: LXMFSwift.LXMRouter, didUpdateMessage message: LXMFSwift.LXMessage) {
            if message.state == .delivered {
                continuation.yield(.delivery(
                    messageHash: message.hash.hexHash,
                    state: "delivered",
                    method: Self.mapDeliveryMethod(message.method),
                    t: Date()
                ))
            }
        }
        func router(_ router: LXMFSwift.LXMRouter, didFailMessage message: LXMFSwift.LXMessage, reason: LXMFSwift.LXMFError) {
            continuation.yield(.delivery(
                messageHash: message.hash.hexHash,
                state: "failed",
                method: Self.mapDeliveryMethod(message.method),
                t: Date()
            ))
        }
        func router(_ router: LXMFSwift.LXMRouter, didConfirmDelivery messageHash: Data) {
            continuation.yield(.delivery(messageHash: messageHash.hexHash, state: "delivered", method: nil, t: Date()))
        }
        func router(_ router: LXMFSwift.LXMRouter, didUpdateSyncState state: LXMFSwift.PropagationTransferState) {}
        func router(_ router: LXMFSwift.LXMRouter, didCompleteSyncWithNewMessages newMessages: Int) {}

        private static func mapDeliveryMethod(
            _ method: LXMFSwift.LXDeliveryMethod
        ) -> RNSAPI.LXDeliveryMethod? {
            switch method {
            case .opportunistic: return .opportunistic
            case .direct: return .direct
            case .propagated: return .propagated
            case .paper: return .paper
            default: return nil
            }
        }
    }
}

// Small hex helper local to this module (Compat's HexExt is in RNSAPI; Data here
// is reticulum-swift's, so use a local extension to avoid ambiguity).
private extension Data {
    var hexHash: String { map { String(format: "%02x", $0) }.joined() }
}
