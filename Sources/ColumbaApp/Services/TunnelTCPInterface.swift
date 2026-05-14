//
//  TunnelTCPInterface.swift
//  ColumbaApp
//
//  A `NetworkInterface` that routes outbound traffic through the
//  Columba Network Extension's `PacketTunnelProvider` instead of
//  through an app-owned `NWConnection`. Inbound packets are fed in
//  from `ExtensionFrameReader`'s drain of `SharedFrameQueue`.
//
//  Architectural rationale (the dual-interface model that obsoletes
//  the old tunnel-mode flip):
//
//  Previously, Columba had ONE `TCPInterface` per configured TCP
//  relay. When the user enabled Background Transport, that interface
//  was flipped into "tunnel mode" mid-session: it gave up its
//  local `NWConnection` and started routing outbound through the
//  extension instead. This worked in steady state but had a fatal
//  edge case at the handoff itself — when tunnel mode engaged, the
//  app-owned socket closed, rnsd noticed the disconnect and removed
//  the path-table entry pointing at it, and the new extension-owned
//  socket had no announce yet because `TCPInterface.beginTunnelMode`
//  keeps state `.connected` (no `notifyStateChange`, so the
//  `auto_announce_on_tcp_reconnect` callback never fires). Bot →
//  phone packets then bounced off rnsd as
//  `Got packet in transport, but no known path to final destination`
//  for the entire suspend window.
//
//  The new model: TWO interfaces are registered with the transport
//  when Background Transport is on. The original `TCPInterface`
//  stays foreground-only (owns its own `NWConnection`, no tunnel
//  mode); this `TunnelTCPInterface` carries the tunneled path.
//  rnsd sees them as two separate clients with two independent
//  path-table entries to `<phone-hash>`. When the app suspends, the
//  foreground socket dies and rnsd removes its path, but the tunnel
//  path stays because the extension's `NWConnection` keeps running.
//  Bot → phone packets route via the tunnel path → extension →
//  `PacketTunnelProvider.maybeScheduleNotification(for:)` → UN
//  notification fires under the host app's bundle identity.
//
//  Outbound: `send(_:)` HDLC-frames the data and hands the framed
//  bytes to `TunnelManager.sendFrame(_:interfaceTag:entityId:)`,
//  which posts them through `sendProviderMessage` to the extension.
//  The extension's `handleAppMessage` forwards them on its own
//  `NWConnection` to rnsd.
//
//  Inbound: when the extension reads a frame from rnsd, it deframes
//  HDLC and writes the packet to `SharedFrameQueue` tagged with the
//  source `entityId`. `ExtensionFrameReader` drains the queue and
//  invokes `onTCPFrameReceived(entityId, data)`. For frames from
//  the tunnel's entityId, the callback routes them via
//  `transport.handleReceivedData(data:, from: self.id)` — which is
//  how the transport handles inbound for any `NetworkInterface`.
//  The interface itself doesn't need to actively receive; the
//  transport's routing layer does that.
//

#if ENABLE_NETWORK_EXTENSION

import Foundation
import ReticulumSwift

/// Fixed interface ID used by the tunnel TCP path. The extension
/// publishes inbound frames with this entityId and the
/// `TunnelManager.sendFrame` outbound call tags frames with it.
public let TUNNEL_TCP_INTERFACE_ID = "tcp-tunnel"

@available(iOS 17.0, macOS 14.0, *)
public actor TunnelTCPInterface: @preconcurrency NetworkInterface {

    // MARK: - NetworkInterface conformance

    /// Fixed to `TUNNEL_TCP_INTERFACE_ID` — there is only ever one
    /// tunnel TCP interface per app process. The extension routes
    /// inbound frames to this id and the outbound `sendFrame` tags
    /// with it.
    public nonisolated let id: String = TUNNEL_TCP_INTERFACE_ID

    /// Synthesized config so the transport's interface bookkeeping
    /// has something to introspect. The `host`/`port` mirror the
    /// foreground TCP entity so the user-facing identity (relay
    /// address) is the same across both interfaces — they're just
    /// two paths to the same rnsd.
    public nonisolated let config: InterfaceConfig

    /// Matches `TCPInterface.hwMtu` — TCP has no practical MTU limit
    /// at the application layer.
    public nonisolated var hwMtu: Int { 262144 }

    public private(set) var state: InterfaceState = .disconnected

    private var delegateRef: WeakDelegate?

    public var delegate: InterfaceDelegate? {
        get { delegateRef?.delegate }
    }

    public func setDelegate(_ delegate: InterfaceDelegate) async {
        delegateRef = WeakDelegate(delegate)
    }

    // MARK: - Outbound

    /// Closure called for each HDLC-framed outbound packet. Bound at
    /// init time to `TunnelManager.sendFrame(_:interfaceTag:entityId:)`
    /// (with `interfaceTag = .tcp` and `entityId = TUNNEL_TCP_INTERFACE_ID`)
    /// so this interface doesn't need a direct dependency on
    /// `TunnelManager`'s type — keeps the interface compilable
    /// outside the `ENABLE_NETWORK_EXTENSION` target if we ever
    /// move it.
    private let sendHook: @Sendable (Data) async -> Void

    // MARK: - Init

    public init(
        config: InterfaceConfig,
        sendHook: @escaping @Sendable (Data) async -> Void
    ) {
        self.config = config
        self.sendHook = sendHook
    }

    // MARK: - Connection lifecycle

    /// Mark the interface connected. The actual TCP socket is owned
    /// by the extension's `PacketTunnelProvider`, so all this method
    /// does is flip our local state + notify the delegate. The
    /// caller (AppServices' tunnel-status observer) ensures this is
    /// only invoked once the underlying VPN tunnel has reached
    /// `.connected`.
    public func connect() async throws {
        guard state != .connected else { return }
        state = .connecting
        notifyStateChange()
        state = .connected
        notifyStateChange()
    }

    /// Mark the interface disconnected. Mirrors `connect()` — the
    /// actual socket teardown happens in the extension when the VPN
    /// session ends. We just notify the transport so the
    /// path-routing logic stops trying to use this interface.
    public func disconnect() async {
        guard state != .disconnected else { return }
        state = .disconnected
        notifyStateChange()
    }

    // MARK: - Send

    public func send(_ data: Data) async throws {
        guard state == .connected else {
            throw InterfaceError.notConnected
        }
        let framed = HDLC.frame(data)
        await sendHook(framed)
    }

    // MARK: - Inbound (from ExtensionFrameReader)

    /// Feed an unframed packet (already HDLC-deframed by the
    /// extension's `extractHDLCFrames`) up to the transport via
    /// the standard delegate channel. Called by AppServices's
    /// `ExtensionFrameReader.onTCPFrameReceived` handler when the
    /// inbound frame's entityId matches `TUNNEL_TCP_INTERFACE_ID`.
    public func receivePacket(_ data: Data) async {
        delegateRef?.delegate?.interface(id: id, didReceivePacket: data)
    }

    // MARK: - Private

    private func notifyStateChange() {
        delegateRef?.delegate?.interface(id: id, didChangeState: state)
    }

    /// Convenience for AppServices to synthesize an `InterfaceConfig`
    /// from a foreground TCP entity's host/port. Reuses the same
    /// host/port so the tunnel interface is logically "another path
    /// to the same relay".
    public static func makeConfig(host: String, port: UInt16) -> InterfaceConfig {
        InterfaceConfig(
            id: TUNNEL_TCP_INTERFACE_ID,
            name: "TCP Tunnel",
            type: .tcp,
            enabled: true,
            mode: .full,
            host: host,
            port: port,
            ifac: nil
        )
    }
}

/// Weak delegate wrapper. Mirrors the same pattern in
/// `reticulum-swift/TCPInterface.swift` so delegate retention
/// matches across interface types.
private final class WeakDelegate: @unchecked Sendable {
    weak var delegate: InterfaceDelegate?
    init(_ delegate: InterfaceDelegate) {
        self.delegate = delegate
    }
}

#endif  // ENABLE_NETWORK_EXTENSION
