import Foundation
import RNSAPI
import LXSTSwift
import os.log

/// Columba's `NetworkTransport` implementation for LXST voice calls.
///
/// Bridges LXSTSwift's transport seam to the Compat RNS layer
/// (`ReticulumTransport` + `Link`) running over `PythonRNSBackend`. It owns all
/// the Reticulum machinery `LXSTSwift.Telephone` used to do inline — telephony
/// destination registration, incoming-link detection, link lifecycle,
/// encryption, packetization, identify, and path resolution — so the library
/// stays transport-agnostic. Mirrors LXST-kt's `PythonNetworkTransport`.
///
/// The seam speaks in the app's universal contact key: the peer's
/// **lxmf.delivery destination hash**. `openOutboundCall` takes it and resolves
/// the identity → telephony destination; `remoteIdentified` reports it
/// (computed from the verified caller identity). No RNS types cross into
/// `Telephone`.
public actor PythonNetworkTransport: NetworkTransport {

    // LXST telephony destination aspect: <identity>.lxst.telephony
    private static let appName = "lxst"
    private static let primitiveName = "telephony"
    // LXMF contact key aspect: <identity>.lxmf.delivery
    private static let lxmfApp = "lxmf"
    private static let lxmfAspect = "delivery"

    private let identity: Identity
    private let transport: ReticulumTransport
    private let pathTable: PathTable?
    private let logger = Logger(subsystem: "network.columba.Columba", category: "PythonNetworkTransport")

    /// The active call link (outbound or accepted inbound), if any.
    private var activeLink: Link?

    // Seam handlers (installed by Telephone).
    private var incomingCallHandler: (@Sendable () async -> Void)?
    private var remoteIdentifiedHandler: (@Sendable (Data) async -> Void)?
    private var receiveHandler: (@Sendable (Data) async -> Void)?
    private var closedHandler: (@Sendable (TransportCloseReason) async -> Void)?

    /// Columba-specific: fired when an inbound link establishes, BEFORE the
    /// caller identifies — lets CallManager `prepareForIncomingCall` (allocate
    /// the CallKit UUID) ahead of the post-identify ringing trigger. Not part
    /// of the `NetworkTransport` protocol.
    private var incomingCallStartedHandler: (@Sendable () async -> Void)?

    public init(identity: Identity, transport: ReticulumTransport, pathTable: PathTable?) {
        self.identity = identity
        self.transport = transport
        self.pathTable = pathTable
    }

    /// Register the local telephony destination and wire incoming-link
    /// detection. Call once after construction, before placing/receiving calls.
    public func start() async {
        let inDest = Destination(
            identity: identity,
            appName: Self.appName,
            aspects: [Self.primitiveName],
            type: .single,
            direction: .in
        )
        await transport.registerDestination(inDest)
        let hexPrefix = inDest.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.error("[PNT] Listening on telephony dest \(hexPrefix, privacy: .public)")

        // The destination-link callback fires pre-establishment; we attach the
        // established callback so we only take over once the link is usable.
        transport.registerDestinationLinkCallback(for: inDest.hash) { [weak self] (link: Link) async in
            await link.setLinkEstablishedCallback { [weak self] (established: Link) async in
                await self?.handleIncomingLinkEstablished(established)
            }
        }
    }

    /// Set the pre-identify incoming-call hook (CallManager.prepareForIncomingCall).
    public func setIncomingCallStartedHandler(_ handler: @escaping @Sendable () async -> Void) {
        incomingCallStartedHandler = handler
    }

    // MARK: - NetworkTransport (outbound)

    public func openOutboundCall(to deliveryHash: Data) async -> Bool {
        guard let pathTable else {
            logger.error("[PNT] openOutboundCall: no path table")
            return false
        }
        // Resolve the peer's delivery hash → identity (public key from announce).
        guard let entry = await pathTable.lookup(destinationHash: deliveryHash),
              entry.publicKeys.count == 64,
              let remoteIdentity = try? Identity(publicKeyBytes: entry.publicKeys) else {
            logger.error("[PNT] openOutboundCall: peer not resolvable from path table")
            return false
        }

        // Build the peer's telephony destination and ensure a path to it.
        let callDest = Destination(
            identity: remoteIdentity,
            appName: Self.appName,
            aspects: [Self.primitiveName],
            type: .single,
            direction: .out
        )
        let pathFound = await transport.awaitPath(for: callDest.hash, timeout: 10.0)
        logger.error("[PNT] path to telephony dest found=\(pathFound, privacy: .public)")
        guard pathFound else {
            // No path after the timeout — the peer is unreachable, so an
            // RNS.Link can't establish anyway. Abort now rather than fall
            // through to a doomed initiateLink that just times out again.
            logger.error("[PNT] no path to telephony dest — aborting outbound call")
            return false
        }

        do {
            let link = try await transport.initiateLink(to: callDest, identity: identity)
            await wireLinkCallbacks(link, incoming: false)
            activeLink = link
            logger.error("[PNT] Outbound link initiated")
            return true
        } catch {
            logger.error("[PNT] initiateLink failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func identifySelf() async {
        guard let link = activeLink else { return }
        do {
            try await link.identify(identity: identity)
        } catch {
            // An identify failure (link torn down mid-handshake, backend error)
            // strands the callee at AVAILABLE until connect-timeout — surface it
            // instead of swallowing via try?, mirroring send()'s logging.
            logger.error("[PNT] identifySelf failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func send(_ payload: Data) async {
        guard let link = activeLink else { return }
        do {
            // Compat's Link.sendBytes encrypts with the link keys and emits the
            // DATA packet internally — no manual packetization needed.
            try await link.sendBytes(payload)
        } catch {
            logger.error("[PNT] send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func closeCall() async {
        guard let link = activeLink else { return }
        // Clear the close callback first so our own teardown doesn't echo back
        // as a spurious remote-close.
        await link.setCloseCallback(nil)
        // Local hangup: tear the Python RNS.Link down (not just flip local
        // state) so the remote peer's link closes promptly instead of waiting
        // for its ~15s keepalive timeout. Do this even when not yet
        // established — aborting an outbound dial during the "calling" window
        // (or a connect-timeout) leaves a `.pending` link whose Python side
        // must still be torn down. teardown() is a no-op on an unwired link.
        await link.teardown()
        activeLink = nil
    }

    public var isCallActive: Bool { activeLink != nil }

    // MARK: - NetworkTransport (inbound handler registration)

    public func setIncomingCallHandler(_ handler: @escaping @Sendable () async -> Void) async {
        incomingCallHandler = handler
    }
    public func setRemoteIdentifiedHandler(_ handler: @escaping @Sendable (Data) async -> Void) async {
        remoteIdentifiedHandler = handler
    }
    public func setReceiveHandler(_ handler: @escaping @Sendable (Data) async -> Void) async {
        receiveHandler = handler
    }
    public func setClosedHandler(_ handler: @escaping @Sendable (TransportCloseReason) async -> Void) async {
        closedHandler = handler
    }

    // MARK: - Internal wiring

    /// Attach packet/close (and, for inbound, identify) callbacks routing to the seam.
    private func wireLinkCallbacks(_ link: Link, incoming: Bool) async {
        await link.setPacketCallback { [weak self] data, _ in
            await self?.deliverReceived(data)
        }
        await link.setCloseCallback { [weak self] reason in
            await self?.deliverClosed(reason)
        }
        if incoming {
            await link.setIdentifyCallbacks(IdentifyAdapter(owner: self))
        }
    }

    private func handleIncomingLinkEstablished(_ link: Link) async {
        // A re-delivered established event for the link we're already on must
        // not be treated as a competing inbound call — otherwise the BUSY
        // branch below would signal BUSY on and tear down our own live link.
        if link === activeLink { return }
        // Already on a call → signal BUSY on the NEW link and tear it down,
        // without disturbing the active one. Mirrors Python LXST
        // Telephony.__incoming_link_established (`signal(STATUS_BUSY, link);
        // link.teardown()`). The busy decision lives here at the incoming-link
        // layer because `activeLink` belongs to the in-progress call; we send
        // the one-byte BUSY signal directly rather than route it through
        // Telephone (which only knows about the active call).
        if activeLink != nil {
            logger.error("[PNT] Incoming link while a call is active — signalling BUSY")
            try? await link.sendBytes(LXSTWireFormat.packSignal(.busy))
            // Tear the Python RNS.Link down (mirrors LXST's `link.teardown()`)
            // so the rejected caller's link closes now rather than on timeout.
            await link.teardown()
            return
        }
        await wireLinkCallbacks(link, incoming: true)
        activeLink = link
        // Notify CallManager (prepare CallKit UUID) then Telephone (send AVAILABLE).
        await incomingCallStartedHandler?()
        await incomingCallHandler?()
    }

    private func deliverReceived(_ data: Data) async {
        await receiveHandler?(data)
    }

    private func deliverClosed(_ reason: TeardownReason) async {
        activeLink = nil
        // A clean remote hangup arrives as initiator_closed on inbound calls
        // (the caller initiated the RNS link) and destination_closed on
        // outbound calls (the callee is the destination); both should surface
        // as a normal "Call ended". Only genuine failures (timeout / network)
        // map to .linkFailed, which drives LXST's error state instead.
        let mapped: TransportCloseReason
        switch reason {
        case .destinationClosed, .initiatorClosed: mapped = .remoteClosed
        default:                                    mapped = .linkFailed
        }
        await closedHandler?(mapped)
    }

    /// Called by the identify adapter once the remote caller is verified.
    fileprivate func handleRemoteIdentified(_ remoteIdentity: Identity) async {
        // Report the caller by their lxmf.delivery hash (the app's contact key).
        let deliveryHash = Destination.hash(
            identity: remoteIdentity,
            appName: Self.lxmfApp,
            aspects: [Self.lxmfAspect]
        )
        await remoteIdentifiedHandler?(deliveryHash)
    }
}

/// Bridges the Compat `IdentifyCallbacks` protocol to the transport actor.
private final class IdentifyAdapter: IdentifyCallbacks, @unchecked Sendable {
    private weak var owner: PythonNetworkTransport?
    init(owner: PythonNetworkTransport) { self.owner = owner }
    func remoteIdentified(_ identity: Identity) async {
        await owner?.handleRemoteIdentified(identity)
    }
}
