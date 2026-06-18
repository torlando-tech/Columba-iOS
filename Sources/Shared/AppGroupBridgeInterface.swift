//
//  AppGroupBridgeInterface.swift
//  Columba Shared
//
//  Model B IPC bridge: a ReticulumSwift `NetworkInterface` that carries RNS
//  frames across the App-Group boundary between the main app (which owns the
//  BLE/RNode radios) and the Network Extension (which owns the single RNS
//  node). This lets the NE's RNS instance be reachable over both TCP (direct,
//  via the NE's own TCP interfaces) AND radio (via this bridge + the app's
//  radio relay).
//
//  Directions (see `SharedFrameQueue` for the queue layout):
//    • send(_:)         — NE→app. The NE's transport wants to transmit `data`;
//                         the bridge HDLC-frames it, enqueues to the `e2a` queue
//                         tagged with the target radio, and pokes the app.
//    • deliverInbound(_:) — app→NE. The app drained a radio-received (already
//                         HDLC-deframed) packet from the `a2e` queue; the bridge
//                         hands it to the transport delegate as an inbound packet.
//
//  COLLISION RULE: this file conforms to `ReticulumSwift.NetworkInterface`, so
//  it imports ReticulumSwift. It MUST import ONLY ReticulumSwift + Foundation
//  and NOT RNSAPI — RNSAPI's Compat layer re-declares NetworkInterface /
//  Destination / Link / etc., and co-importing both produces an un-fixable
//  ambiguity cascade. All ReticulumSwift types below are referenced unqualified
//  (only ReticulumSwift is in scope, so they are unambiguous).
//
//  REGISTRATION (Track A5, NOT done here): registering this interface into the
//  NE's `ReticulumTransport` and running the app-side radio relay loop (drain
//  `e2a` → transmit on radio; receive on radio → deframe → enqueue `a2e` →
//  post `radioFrameReady`) depends on the NE running the RNS backend (Model B).
//  A1 delivers only the conforming interface type + the bidirectional queue,
//  compile-validated. The NE target does not yet link ReticulumSwift, so this
//  file is currently a member of the ColumbaApp target only; when A5 links
//  ReticulumSwift into the ColumbaNetworkExtension target, add this file to that
//  target's Sources phase as well.
//

import Foundation
import ReticulumSwift

/// App-Group IPC bridge presented to a `ReticulumTransport` as a single
/// `NetworkInterface`. Frames flowing out of the transport (`send`) are queued
/// for the peer process to transmit on a radio; radio receptions delivered by
/// the peer process (`deliverInbound`) are surfaced to the transport delegate.
///
/// An `actor` for the same reasons `TCPInterface` is: the protocol is
/// `Sendable` and the delegate is held weakly behind an actor-isolated wrapper.
public actor AppGroupBridgeInterface: @preconcurrency NetworkInterface {

    // MARK: - NetworkInterface conformance

    /// Stable identifier for the single bridge interface.
    public let id: String

    /// Full-mode interface configuration. `.full` propagates announces in both
    /// directions (radio↔TCP), which is the whole point of the bridge: the NE's
    /// RNS node should relay announces between its TCP peers and the radio mesh.
    public let config: InterfaceConfig

    /// Current connection state. Reflects whether the IPC channel is live:
    /// `.connected` once `connect()` has been called (the App-Group queues are
    /// always reachable in-process), `.disconnected` after `disconnect()`.
    public private(set) var state: InterfaceState = .disconnected

    /// Hardware MTU — the radio's negotiated MTU. Caps the link MDU during
    /// MTU discovery so the NE never hands the app a frame the radio can't
    /// transmit. Supplied at init by whoever knows the active radio's MTU.
    public let hwMtu: Int

    // MARK: - Bridge state

    /// Which radio NE-originated frames (`send`) should be transmitted on, and
    /// the tag stamped onto `e2a` queue entries so the app's relay knows where
    /// to route them.
    private let targetRadio: FrameInterfaceTag

    /// App→NE / NE→app queue handles. `send` writes to `e2a`; the peer process
    /// drains it. `deliverInbound` is fed by the local process draining `a2e`.
    private let e2aQueue: SharedFrameQueue

    /// Darwin notification posted after writing to `e2a` so the peer wakes and
    /// drains promptly.
    private let outboundNotificationName: String

    // MARK: - Delegate

    /// Weak wrapper so the actor doesn't retain the transport delegate.
    /// Mirrors `TCPInterface`'s pattern (weak refs are atomically nil-safe).
    private var delegateRef: WeakBridgeDelegate?

    /// Delegate for interface events (the `ReticulumTransport` wrapper).
    public var delegate: InterfaceDelegate? {
        get { delegateRef?.delegate }
        set { delegateRef = newValue.map { WeakBridgeDelegate($0) } }
    }

    // MARK: - Initialization

    /// Create the App-Group bridge interface.
    ///
    /// - Parameters:
    ///   - id: Interface identifier. Defaults to `"appgroup-bridge"`.
    ///   - appGroupIdentifier: App Group container shared with the peer process.
    ///   - targetRadio: Radio that `send`-direction frames are transmitted on
    ///     (and the tag written to the `e2a` queue). Defaults to `.bleMesh`.
    ///   - hwMtu: The radio's negotiated hardware MTU (caps link MDU).
    ///   - mode: Interface mode. Defaults to `.full` (announces propagate both
    ///     ways).
    public init(
        id: String = "appgroup-bridge",
        appGroupIdentifier: String,
        targetRadio: FrameInterfaceTag = .bleMesh,
        hwMtu: Int,
        mode: InterfaceMode = .full
    ) {
        self.id = id
        self.hwMtu = hwMtu
        self.targetRadio = targetRadio
        self.e2aQueue = SharedFrameQueue(
            appGroupIdentifier: appGroupIdentifier,
            name: SharedFrameQueueName.e2a
        )
        self.outboundNotificationName = SharedDefaultsConstants.packetReadyNotificationName
        self.config = InterfaceConfig(
            id: id,
            name: "App-Group Bridge",
            type: .tcp,
            enabled: true,
            mode: mode,
            host: "",
            port: 0,
            ifac: nil
        )
    }

    // MARK: - Lifecycle

    /// "Connect" the bridge. The App-Group queues are always reachable in
    /// process, so this just marks the IPC channel live and notifies the
    /// delegate of the state change.
    public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connected
        notifyStateChange()
    }

    /// "Disconnect" the bridge — marks the IPC channel down. Queued frames are
    /// left in place for the peer to drain.
    public func disconnect() async {
        guard state != .disconnected else { return }
        state = .disconnected
        notifyStateChange()
    }

    // MARK: - Outbound (NE→app)

    /// Send a packet out through the bridge (NE→app direction).
    ///
    /// HDLC-frames the payload (matching `TCPInterface.send`, which frames with
    /// `HDLC.frame` before handing bytes to its transport), enqueues the framed
    /// bytes onto the `e2a` queue tagged with the target radio, then posts the
    /// NE→app Darwin notification so the peer process drains and transmits.
    ///
    /// - Parameter data: Raw, unframed Reticulum packet to transmit.
    public func send(_ data: Data) async throws {
        guard state == .connected else {
            throw InterfaceError.notConnected
        }
        let framed = HDLC.frame(data)
        e2aQueue.append(frame: framed, interfaceTag: targetRadio.rawValue)
        postOutboundNotification()
    }

    // MARK: - Inbound (app→NE)

    /// Deliver a radio-received packet into the transport (app→NE direction).
    ///
    /// Called by the local process's relay loop after it drains a frame from
    /// the `a2e` queue. The frame is expected to be ALREADY HDLC-deframed — the
    /// relay that owns the radio strips framing before enqueueing, mirroring how
    /// `PacketTunnelProvider` runs `extractHDLCFrames` on inbound TCP before
    /// writing to the queue. The bridge therefore forwards `frame` straight to
    /// the delegate as a complete packet, exactly as `TCPInterface` does once it
    /// has extracted a frame.
    ///
    /// - Parameter frame: Complete, unframed inbound Reticulum packet.
    public func deliverInbound(_ frame: Data) {
        guard let delegate = delegateRef?.delegate else { return }
        delegate.interface(id: id, didReceivePacket: frame)
    }

    // MARK: - Delegate plumbing

    /// Set the delegate for receiving interface events. Satisfies the
    /// `NetworkInterface` protocol requirement.
    public func setDelegate(_ delegate: InterfaceDelegate) async {
        self.delegate = delegate
    }

    /// Notify the delegate of the current state. Mirrors `TCPInterface`.
    private func notifyStateChange() {
        let currentState = state
        let interfaceId = id
        guard let delegate = delegateRef?.delegate else { return }
        delegate.interface(id: interfaceId, didChangeState: currentState)
    }

    // MARK: - Darwin notification

    /// Post the NE→app Darwin notification so the peer process drains `e2a`.
    private func postOutboundNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(outboundNotificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

// MARK: - WeakBridgeDelegate

/// Weak wrapper for the delegate reference held inside the actor.
///
/// `@unchecked Sendable` because weak references are inherently thread-safe
/// (they become nil atomically when the referent is deallocated). Named
/// distinctly from `TCPInterface`'s private `WeakDelegate` to avoid any
/// same-module collision should both files ever land in one target.
private final class WeakBridgeDelegate: @unchecked Sendable {
    weak var delegate: InterfaceDelegate?

    init(_ delegate: InterfaceDelegate) {
        self.delegate = delegate
    }
}
