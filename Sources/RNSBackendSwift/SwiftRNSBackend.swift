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
