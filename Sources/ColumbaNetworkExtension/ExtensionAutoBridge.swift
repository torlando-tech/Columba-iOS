//
//  ExtensionAutoBridge.swift
//  ColumbaNetworkExtension
//
//  AutoInterface protocol implemented on Apple's Network framework
//  (`NWMulticastGroup` for HELLO discovery, `NWListener` for inbound
//  unicast UDP, per-peer `NWConnection` for outbound) so it actually
//  works inside an `NEPacketTunnelProvider` — POSIX sockets bound to
//  link-local IPv6 addresses succeed at bind time but iOS sandboxes
//  inbound delivery to the system networking stack instead of our
//  socket. The Network framework primitives are Apple's supported
//  path for extensions and don't have that limitation.
//
//  Wire compatibility with reticulum-swift's `AutoInterface`:
//    – multicast group is `ff12:0:…` derived from the configured
//      groupId (`AutoInterfaceConstants.multicastAddress(for:)`).
//    – HELLO beacons are 32-byte SHA-256 tokens
//      (`AutoInterfaceConstants.discoveryToken(groupId:address:)`).
//    – data is plain UDP datagrams on `defaultDataPort` (42671).
//    – announce / peering / mute timing constants are reused from
//      `AutoInterfaceConstants` so behaviour matches the app's
//      `AutoInterface` and Sideband.
//

import Foundation
import Network
import Darwin
@preconcurrency import ReticulumSwift

/// Drives an extension-side AutoInterface using Apple's Network
/// framework primitives. Exposes a tiny surface (`start` /
/// `stop` / `send`) so `PacketTunnelProvider` doesn't need to know
/// about the protocol.
final class ExtensionAutoBridge: @unchecked Sendable {

    // MARK: - Dependencies

    private let frameQueue: SharedFrameQueue
    private let postNotif: () -> Void

    // MARK: - State

    /// Currently-applied group id; nil when stopped. Used by
    /// `PacketTunnelProvider`'s diff logic.
    private(set) var groupId: String?

    private var multicastAddress: String = ""
    private var discoveryPort: UInt16 = AutoInterfaceConstants.defaultDiscoveryPort
    private var dataPort: UInt16 = AutoInterfaceConstants.defaultDataPort

    /// Multicast group for sending and receiving HELLO beacons.
    private var multicastGroup: NWConnectionGroup?

    /// Listener on `dataPort` for inbound unicast data from peers.
    private var dataListener: NWListener?

    /// Open outbound `NWConnection`s keyed by peer's link-local
    /// IPv6 address (without scope id). Lazily created when a peer
    /// is first discovered or when we receive data from one.
    private var peerConnections: [String: NWConnection] = [:]

    /// Last time we heard a valid HELLO from each peer. Peers older
    /// than `peeringTimeout` are pruned.
    private var peerLastHeard: [String: Date] = [:]

    /// Our own link-local IPv6 addresses — used to filter out our
    /// own multicast echoes and to compute the discovery token we
    /// announce on each interface.
    private var ownAddresses: Set<String> = []

    private var announceTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    /// Serial queue for state mutations (peers dict, ownAddresses,
    /// etc.) so async network callbacks don't race each other.
    private let stateQueue = DispatchQueue(label: "network.columba.tunnel.auto.state")

    // MARK: - Init

    init(frameQueue: SharedFrameQueue, postNotif: @escaping () -> Void) {
        self.frameQueue = frameQueue
        self.postNotif = postNotif
    }

    // MARK: - Public API

    func start(groupId: String) {
        stop()
        self.groupId = groupId
        self.multicastAddress = AutoInterfaceConstants.multicastAddress(for: groupId)
        self.ownAddresses = Self.discoverLinkLocalAddresses()

        ExtensionDiagLog.log("[EXT/Auto] starting groupId=\(groupId) mcast=\(multicastAddress) own=\(ownAddresses)")

        startMulticast()
        startDataListener()
        startAnnounceLoop()
        startMaintenanceLoop()
    }

    func stop() {
        announceTask?.cancel()
        announceTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil

        multicastGroup?.cancel()
        multicastGroup = nil

        dataListener?.cancel()
        dataListener = nil

        stateQueue.sync {
            for (_, conn) in peerConnections {
                conn.cancel()
            }
            peerConnections.removeAll()
            peerLastHeard.removeAll()
            ownAddresses.removeAll()
        }
        groupId = nil
    }

    /// Forward outbound bytes from the app to every known peer.
    func send(_ data: Data) {
        let conns: [NWConnection] = stateQueue.sync {
            Array(peerConnections.values)
        }
        guard !conns.isEmpty else {
            ExtensionDiagLog.log("[EXT/Auto] TX dropped \(data.count)B — no peers")
            return
        }
        for conn in conns {
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    ExtensionDiagLog.log("[EXT/Auto] TX \(data.count)B failed: \(error)")
                }
            })
        }
        ExtensionDiagLog.log("[EXT/Auto] TX \(data.count)B fanned out to \(conns.count)")
    }

    // MARK: - Multicast HELLO discovery

    private func startMulticast() {
        guard let port = NWEndpoint.Port(rawValue: discoveryPort),
              let mcastIP = IPv6Address(multicastAddress) else {
            ExtensionDiagLog.log("[EXT/Auto] invalid multicast endpoint")
            return
        }

        let mcastGroup: NWMulticastGroup
        do {
            mcastGroup = try NWMulticastGroup(for: [
                .hostPort(host: .ipv6(mcastIP), port: port)
            ])
        } catch {
            ExtensionDiagLog.log("[EXT/Auto] NWMulticastGroup init failed: \(error)")
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi
        params.includePeerToPeer = false

        let group = NWConnectionGroup(with: mcastGroup, using: params)
        self.multicastGroup = group

        group.stateUpdateHandler = { state in
            ExtensionDiagLog.log("[EXT/Auto] multicast state: \(state)")
        }

        group.setReceiveHandler(maximumMessageSize: 256, rejectOversizedMessages: false) { [weak self] message, content, _ in
            guard let self, let content else { return }
            // HELLO tokens are exactly 32 bytes.
            guard content.count == 32 else { return }

            // Source endpoint tells us who multicasted — that's the
            // peer's link-local IPv6 address.
            guard let endpoint = message.remoteEndpoint,
                  let sourceAddr = Self.linkLocalString(from: endpoint) else {
                return
            }
            self.handleHello(token: content, sourceAddress: sourceAddr)
        }

        group.start(queue: .global(qos: .utility))
    }

    private func handleHello(token: Data, sourceAddress: String) {
        guard let groupId else { return }
        let groupBytes = groupId.data(using: .utf8) ?? Data()
        let expected = AutoInterfaceConstants.discoveryToken(
            groupId: groupBytes,
            address: sourceAddress
        )
        guard token == expected else {
            // Mismatched group — ignore.
            return
        }

        // Don't peer with ourselves.
        if ownAddresses.contains(sourceAddress) {
            return
        }

        // Reserve the peer slot atomically inside the state queue so
        // a burst of HELLOs doesn't all observe a nil entry and each
        // create a duplicate `NWConnection` to the same peer.
        let newConn: NWConnection? = stateQueue.sync {
            peerLastHeard[sourceAddress] = Date()
            if peerConnections[sourceAddress] != nil { return nil }
            guard let port = NWEndpoint.Port(rawValue: dataPort),
                  let host = IPv6Address(sourceAddress) else { return nil }
            let params = NWParameters.udp
            params.requiredInterfaceType = .wifi
            params.includePeerToPeer = false
            let conn = NWConnection(host: .ipv6(host), port: port, using: params)
            peerConnections[sourceAddress] = conn
            return conn
        }

        if let conn = newConn {
            ExtensionDiagLog.log("[EXT/Auto] peer added: \(sourceAddress)")
            conn.stateUpdateHandler = { state in
                ExtensionDiagLog.log("[EXT/Auto] peer conn \(sourceAddress) state: \(state)")
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    // MARK: - Inbound unicast data

    private func startDataListener() {
        guard let port = NWEndpoint.Port(rawValue: dataPort) else { return }
        // Don't constrain `requiredInterfaceType` — for an `NWListener`
        // it can prevent the listener from accepting packets that
        // arrive on the tunnel's view of the routing table. Let iOS
        // pick.
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            ExtensionDiagLog.log("[EXT/Auto] NWListener init failed: \(error)")
            return
        }
        self.dataListener = listener

        listener.stateUpdateHandler = { state in
            ExtensionDiagLog.log("[EXT/Auto] data listener state: \(state)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            ExtensionDiagLog.log("[EXT/Auto] data listener accepted from \(connection.endpoint)")
            self?.handleIncomingData(connection)
        }

        listener.start(queue: .global(qos: .utility))
    }

    private func handleIncomingData(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, isComplete, error in
            if let content, !content.isEmpty {
                self?.frameQueue.append(frame: content, interfaceTag: FrameInterfaceTag.auto.rawValue)
                self?.postNotif()
                ExtensionDiagLog.log("[EXT/Auto] RX \(content.count)B from \(connection?.endpoint.debugDescription ?? "?")")
            }
            if let error {
                ExtensionDiagLog.log("[EXT/Auto] data RX error: \(error)")
                connection?.cancel()
                return
            }
            if isComplete {
                connection?.cancel()
                return
            }
            // UDP "connection" stays open; keep reading.
            if let conn = connection {
                self?.receiveLoop(conn)
            }
        }
    }

    // MARK: - Outbound per-peer

    private func removePeer(_ address: String) {
        let conn: NWConnection? = stateQueue.sync {
            let c = peerConnections.removeValue(forKey: address)
            peerLastHeard.removeValue(forKey: address)
            return c
        }
        conn?.cancel()
        ExtensionDiagLog.log("[EXT/Auto] peer removed: \(address)")
    }

    // MARK: - Periodic loops

    private func startAnnounceLoop() {
        announceTask = Task { [weak self] in
            // Mirror reticulum-swift's behaviour: a couple of beacons
            // up-front (so peers find us quickly) then fall into the
            // normal cadence.
            for _ in 0..<3 {
                self?.sendHellos()
                try? await Task.sleep(for: .milliseconds(200))
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AutoInterfaceConstants.announceInterval))
                self?.sendHellos()
            }
        }
    }

    private func sendHellos() {
        guard let groupId else { return }
        let groupBytes = groupId.data(using: .utf8) ?? Data()
        for ownAddr in ownAddresses {
            let token = AutoInterfaceConstants.discoveryToken(
                groupId: groupBytes,
                address: ownAddr
            )
            multicastGroup?.send(content: token, completion: { error in
                if let error {
                    ExtensionDiagLog.log("[EXT/Auto] HELLO send failed for \(ownAddr): \(error)")
                }
            })
        }
    }

    private func startMaintenanceLoop() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AutoInterfaceConstants.peerJobInterval))
                self?.expireStalePeers()
            }
        }
    }

    private func expireStalePeers() {
        let now = Date()
        let timeout = AutoInterfaceConstants.peeringTimeout
        let stale: [String] = stateQueue.sync {
            peerLastHeard.compactMap { addr, lastHeard in
                now.timeIntervalSince(lastHeard) > timeout ? addr : nil
            }
        }
        for addr in stale {
            removePeer(addr)
        }
    }

    // MARK: - Helpers

    /// Walk `getifaddrs` and collect Wi-Fi link-local IPv6
    /// addresses. We use these to compute the discovery token we
    /// announce and to filter out our own multicast echoes.
    static func discoverLinkLocalAddresses() -> Set<String> {
        var addresses = Set<String>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return addresses }
        defer { freeifaddrs(ifap) }

        var ptr = ifap
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let saPtr = p.pointee.ifa_addr,
                  saPtr.pointee.sa_family == sa_family_t(AF_INET6) else { continue }

            // Only Wi-Fi-shaped interfaces (en0, en1, …) — skip
            // tunnels (utun*), loopback, etc.
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            let sin6 = saPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            // Link-local prefix is fe80::/10 — first byte 0xfe, top
            // two bits of second byte 10xxxxxx → 0x80…0xbf.
            let bytes = withUnsafePointer(to: sin6.sin6_addr) { ptr in
                UnsafeRawPointer(ptr).load(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)
            }
            guard bytes.0 == 0xfe, (bytes.1 & 0xc0) == 0x80 else { continue }

            var buf = [Int8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var addrCopy = sin6.sin6_addr
            inet_ntop(AF_INET6, &addrCopy, &buf, socklen_t(INET6_ADDRSTRLEN))
            let s = String(cString: buf)
            addresses.insert(s)
        }
        return addresses
    }

    /// Pull the link-local address string out of an `NWEndpoint`,
    /// stripping the `%scope` suffix if present.
    static func linkLocalString(from endpoint: NWEndpoint) -> String? {
        let desc: String
        switch endpoint {
        case .hostPort(let host, _):
            desc = "\(host)"
        default:
            desc = "\(endpoint)"
        }
        // NWEndpoint stringifies IPv6 as `<addr>%<scope>` for
        // link-local. Reticulum's discovery token is computed over
        // the bare address, so strip the scope.
        if let pct = desc.firstIndex(of: "%") {
            return String(desc[..<pct])
        }
        return desc
    }
}
