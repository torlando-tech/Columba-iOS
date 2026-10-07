import Foundation
import RNSAPI
import LXSTSwift
import os.log

/// Columba's `NetworkTransport` for Model B, where the RNS node (and the live
/// RNS.Link used by LXST voice) runs in the **Network Extension**, not the app.
///
/// The app is UI-only under Model B: LXSTSwift's `Telephone` (codec, RTP
/// framing, echo cancellation, CallKit, the call state machine) still runs
/// here, but the RNS link it drives is owned by the NE Python RNS. This actor
/// is the transport seam:
///
///   * **Send side** - `openOutboundCall` / `identifySelf` / `send` /
///     `closeCall` marshal to the four `RnsTelephony` link ops on the proxy
///     backend (`openLink` / `linkSend` / `linkIdentify` / `linkTeardown`),
///     which ride IPC to the NE. The NE's Python `open_link` / `link_send` /
///     `link_identify` / `link_teardown` do the actual RNS work.
///   * **Receive side** - the NE emits `link_state` / `link_packet` /
///     `link_identified` events; the app drains them (ping-driven, no poll) and
///     `AppServices.handlePythonEvent` re-posts them as the
///     `ColumbaPythonLinkState` / `ColumbaPythonLinkPacket` /
///     `ColumbaPythonLinkIdentified` notifications. This actor observes those
///     and drives `Telephone` through the `NetworkTransport` handler seam.
///
/// It mirrors the Model A `PythonNetworkTransport` (same handler wiring, same
/// BUSY-on-inbound-while-busy behavior, same delivery-hash contact reporting)
/// but talks to the NE over IPC + notifications instead of an in-process
/// `ReticulumTransport` / `Link`. Mirrors LXST-kt's cross-process transport.
public actor ModelBNetworkTransport: ColumbaLXSTTransport {

    // LXST telephony destination aspect: <identity>.lxst.telephony
    private static let appName = "lxst"
    private static let primitiveName = "telephony"
    // LXMF contact key aspect: <identity>.lxmf.delivery
    private static let lxmfApp = "lxmf"
    private static let lxmfAspect = "delivery"

    /// Resolves the proxy backend's telephony facet at CALL time, not at
    /// construction. Under Model B the backend is created by `startPythonBackend`
    /// AFTER the CallManager is built, and `restartPythonBackend` reassigns
    /// it - so capturing the `RnsTelephony` ref at init time would grab `nil`
    /// (or go stale on restart). The provider is `@MainActor` (it reads
    /// `AppServices.backend`) and the transport awaits it, which hops to the
    /// main actor; the call methods are already async so that is free.
    private let backendProvider: @Sendable () async -> (any RnsTelephony)?
    private let pathTable: PathTable?
    private let logger = Logger(subsystem: "network.columba.Columba", category: "ModelBNetworkTransport")

    /// Current telephony facet (nil until the backend is up; a call made before
    /// then fails fast with a log rather than a crash).
    private func telephony() async -> (any RnsTelephony)? {
        if let t = await backendProvider() {
            return t
        }
        logger.warning("[MBNT] backend not ready - telephony unavailable")
        return nil
    }

    // MARK: Active link state

    /// The NE-assigned link id of the current call (outbound or accepted
    /// inbound), if any. `nil` = no active call.
    private var activeLinkId: Int?
    /// True when `activeLinkId` is an inbound (remote-initiated) link.
    private var isInboundLink = false

    /// Public-key hints keyed by the exact telephony destination that LXSTSwift
    /// passes to `openOutboundCall`. Lets us build + verify the destination and
    /// hand the NE the key for identity recall before the path resolves.
    private var outboundIdentityHints: [Data: Data] = [:]

    // MARK: Seam handlers (installed by Telephone).

    private var incomingCallHandler: (@Sendable () async -> Void)?
    private var remoteIdentifiedHandler: (@Sendable (Data) async -> Void)?
    private var receiveHandler: (@Sendable (Data) async -> Void)?
    private var closedHandler: (@Sendable (TransportCloseReason) async -> Void)?
    /// Columba-specific: fired when an inbound link establishes, BEFORE the
    /// caller identifies - lets CallManager `prepareForIncomingCall` (allocate
    /// the CallKit UUID) ahead of the post-identify ringing trigger. Not part
    /// of the `NetworkTransport` protocol (same as Model A's transport).
    private var incomingCallStartedHandler: (@Sendable () async -> Void)?

    /// Darwin-notification observer tokens.
    private var stateToken: NSObjectProtocol?
    private var packetToken: NSObjectProtocol?
    private var identifiedToken: NSObjectProtocol?
    private var observersInstalled = false

    public init(backendProvider: @escaping @Sendable () async -> (any RnsTelephony)?, pathTable: PathTable?) {
        self.backendProvider = backendProvider
        self.pathTable = pathTable
    }

    /// Install the link-event notification observers. Call once after
    /// construction, before placing/receiving calls. Idempotent. (The NE
    /// registers the `lxst.telephony` destination itself at node start, so there
    /// is no app-side destination registration to mirror - unlike Model A.)
    public func start() async {
        installLinkEventObservers()
        logger.info("[MBNT] started (link-event observers installed)")
    }

    /// Set the pre-identify incoming-call hook (CallManager.prepareForIncomingCall).
    public func setIncomingCallStartedHandler(_ handler: @escaping @Sendable () async -> Void) {
        incomingCallStartedHandler = handler
    }

    // MARK: - NetworkTransport (outbound)

    /// Stage the canonical target before `Telephone.call` invokes the neutral
    /// `NetworkTransport` seam (mirrors Model A's `PythonNetworkTransport`).
    func prepareOutboundCall(_ target: TelephonyCallTarget) {
        outboundIdentityHints[target.destinationHash] = target.publicKeys
    }

    public func openOutboundCall(to telephonyHash: Data) async -> Bool {
        let hintedKeys = outboundIdentityHints.removeValue(forKey: telephonyHash)
        let cachedKeys = await pathTable?.lookup(destinationHash: telephonyHash)?.publicKeys
        guard let publicKeys = [hintedKeys, cachedKeys].compactMap({ $0 }).first(where: { $0.count == 64 }),
              let remoteIdentity = try? Identity(publicKeyBytes: publicKeys) else {
            logger.error("[MBNT] openOutboundCall: telephony identity unavailable")
            return false
        }

        // Rebuild + verify the exact telephony destination before opening a link
        // so a mismatched staged key fails now, not mid-call.
        let callDest = Destination(
            identity: remoteIdentity,
            appName: Self.appName,
            aspects: [Self.primitiveName],
            type: .single,
            direction: .out
        )
        guard callDest.hash == telephonyHash else {
            logger.error("[MBNT] openOutboundCall: telephony identity mismatch")
            return false
        }

        // Delegate the reachability probe + link open to the NE. The NE's
        // `open_link` performs a bounded path request (up to ~10s) and returns
        // the NE-assigned link id. (Model A resolves the path first; under Model
        // B the NE is authoritative on routing, so we skip the app-side path
        // table probe and let the link establishment be the reachability signal.)
        let publicKeysHex = publicKeys.toHex()
        let destHex = telephonyHash.toHex()
        guard let telephony = await self.telephony() else { return false }
        do {
            let result = try await telephony.openLink(
                destHashHex: destHex,
                aspect: "\(Self.appName).\(Self.primitiveName)",
                identityPublicKeyHex: publicKeysHex
            )
            guard result.ok, result.linkId != 0 else {
                logger.error("[MBNT] openLink failed: reason=\(result.reason, privacy: .public)")
                return false
            }
            activeLinkId = result.linkId
            isInboundLink = false
            logger.error("[MBNT] outbound link initiated linkId=\(result.linkId) dest=\(String(destHex.prefix(8)), privacy: .public)")
            return true
        } catch {
            logger.error("[MBNT] openLink threw: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func identifySelf() async {
        guard let linkId = activeLinkId, let telephony = await self.telephony() else { return }
        do {
            _ = try await telephony.linkIdentify(linkId: linkId)
        } catch {
            logger.error("[MBNT] identifySelf failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func send(_ payload: Data) async {
        guard let linkId = activeLinkId, let telephony = await self.telephony() else { return }
        do {
            _ = try await telephony.linkSend(linkId: linkId, data: payload)
        } catch {
            // A dropped frame: log + continue (the codec / comfort-noise and the
            // NE's own retransmission absorb a single failed frame). Never abort
            // the call over one frame.
            logger.debug("[MBNT] linkSend failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func closeCall() async {
        guard let linkId = activeLinkId else { return }
        // Clear the active link BEFORE tearing down so our own `link_state=closed`
        // event (fired by the NE's teardown) is not re-delivered as a spurious
        // remote-close (mirrors Model A's setCloseCallback(nil) before teardown).
        activeLinkId = nil
        isInboundLink = false
        guard let telephony = await self.telephony() else { return }
        do {
            _ = try await telephony.linkTeardown(linkId: linkId)
        } catch {
            logger.debug("[MBNT] linkTeardown failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public var isCallActive: Bool { activeLinkId != nil }

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

    // MARK: - Link-event observer wiring (receive side)

    private func installLinkEventObservers() {
        guard !observersInstalled else { return }
        let center = NotificationCenter.default

        stateToken = center.addObserver(
            forName: Notification.Name("ColumbaPythonLinkState"),
            object: nil, queue: nil
        ) { [weak self] note in
            Task { await self?.handleLinkState(note) }
        }
        packetToken = center.addObserver(
            forName: Notification.Name("ColumbaPythonLinkPacket"),
            object: nil, queue: nil
        ) { [weak self] note in
            Task { await self?.handleLinkPacket(note) }
        }
        identifiedToken = center.addObserver(
            forName: Notification.Name("ColumbaPythonLinkIdentified"),
            object: nil, queue: nil
        ) { [weak self] note in
            Task { await self?.handleLinkIdentified(note) }
        }
        observersInstalled = true
    }

    deinit {
        let center = NotificationCenter.default
        if let t = stateToken { center.removeObserver(t) }
        if let t = packetToken { center.removeObserver(t) }
        if let t = identifiedToken { center.removeObserver(t) }
    }

    private func noteLinkId(_ note: Notification) -> Int? {
        note.userInfo?["linkId"] as? Int
    }

    private func handleLinkState(_ note: Notification) async {
        let linkId = noteLinkId(note)
        let state = (note.userInfo?["state"] as? String) ?? ""
        let reason = (note.userInfo?["reason"] as? String) ?? ""
        let inbound = (note.userInfo?["inbound"] as? Bool) ?? false
        guard let linkId else { return }

        switch state {
        case "established":
            // Idempotency (P1 #6): a re-delivered `link_state=established` for the
            // link we are ALREADY active on must be ignored. The ackInbox flow is
            // at-least-once: if a drain reply is lost the same established row is
            // re-delivered on the next drain, and treating that as a competing
            // inbound call would BUSY + teardown OUR OWN live link. (This is the
            // "link === activeLink" early return Model A does.) A genuinely
            // competing inbound call is a DIFFERENT linkId, so it falls through.
            guard activeLinkId != linkId else { return }
            guard inbound else {
                // Outbound establishment for a link we do not yet track is already
                // reflected in activeLinkId (set when openLink returned); a stray
                // outbound established for an untracked id is dropped.
                return
            }
            await handleIncomingLinkEstablished(linkId: linkId)
        case "closed":
            // Only the close of OUR active link is call-relevant; a stray
            // closed for an unrelated/stale link id is dropped.
            guard let active = activeLinkId, active == linkId else { return }
            // Clean remote hangup arrives as initiator_closed on inbound calls
            // (the caller initiated the RNS link) and destination_closed on
            // outbound calls (the callee is the destination); both are a normal
            // "Call ended". Genuine failures map to .linkFailed.
            let mapped: TransportCloseReason
            switch reason {
            case "destination_closed", "initiator_closed": mapped = .remoteClosed
            default: mapped = .linkFailed
            }
            activeLinkId = nil
            isInboundLink = false
            logger.error("[MBNT] link \(linkId) closed (remote) reason=\(reason.isEmpty ? "n/a" : reason, privacy: .public)")
            await closedHandler?(mapped)
        default:
            break // "establishing" et al - purely informational
        }
    }

    private func handleLinkPacket(_ note: Notification) async {
        let linkId = noteLinkId(note)
        guard let active = activeLinkId, let linkId, active == linkId else { return }
        guard let data = note.userInfo?["data"] as? Data else { return }
        await receiveHandler?(data)
    }

    private func handleLinkIdentified(_ note: Notification) async {
        let linkId = noteLinkId(note)
        // Only the identify on OUR active link matters (an outbound caller we
        // dialed, or an inbound caller revealing themselves).
        guard let active = activeLinkId, let linkId, active == linkId else { return }

        // The caller is reported by their `<identity>.lxmf.delivery` hash (the
        // app's contact key), computed from the remote's 64-byte public key that
        // the NE carried on the `link_identified` event.
        let pubHex = (note.userInfo?["publicKeyHex"] as? String) ?? ""
        guard !pubHex.isEmpty,
              let publicKeys = try? pubHex.hexToData(),
              publicKeys.count == 64,
              let remoteIdentity = try? Identity(publicKeyBytes: publicKeys) else {
            // No public key on the event (e.g. the NE couldn't resolve it). Fall
            // back to the identity hash if it is a usable delivery-hash shape;
            // otherwise drop (the call still rings, just without a resolved
            // contact).
            let fallbackHex = (note.userInfo?["identityHashHex"] as? String) ?? ""
            if !fallbackHex.isEmpty, let fallback = try? fallbackHex.hexToData(), !fallback.isEmpty {
                await remoteIdentifiedHandler?(fallback)
            } else {
                logger.error("[MBNT] link identified with no public key - caller not resolvable")
            }
            return
        }
        let deliveryHash = Destination.hash(
            identity: remoteIdentity,
            appName: Self.lxmfApp,
            aspects: [Self.lxmfAspect]
        )
        await remoteIdentifiedHandler?(deliveryHash)
    }

    private func handleIncomingLinkEstablished(linkId: Int) async {
        // Already on a call → signal BUSY on the NEW link and tear it down,
        // without disturbing the active one. Mirrors Model A's
        // PythonNetworkTransport.handleIncomingLinkEstablished (and Python LXST's
        // Telephony.__incoming_link_established). The busy decision lives at the
        // incoming-link layer because `activeLinkId` is the in-progress call.
        if activeLinkId != nil {
            logger.error("[MBNT] incoming link while a call is active - signalling BUSY")
            // Send BUSY on the NEW inbound link (the one that just arrived) and
            // tear it down so the rejected caller's link closes now rather than
            // waiting for its ~15s keepalive timeout. The active (in-progress)
            // link is left untouched.
            guard let telephony = await self.telephony() else { return }
            let busy = LXSTWireFormat.packSignal(.busy)
            _ = try? await telephony.linkSend(linkId: linkId, data: busy)
            _ = try? await telephony.linkTeardown(linkId: linkId)
            return
        }
        activeLinkId = linkId
        isInboundLink = true
        logger.error("[MBNT] inbound link established linkId=\(linkId)")
        // Notify CallManager (prepare CallKit UUID) then Telephone (send AVAILABLE).
        await incomingCallStartedHandler?()
        await incomingCallHandler?()
    }
}
