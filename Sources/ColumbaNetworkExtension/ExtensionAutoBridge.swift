//
//  ExtensionAutoBridge.swift
//  ColumbaNetworkExtension
//
//  Hybrid AutoInterface bridge for the Network Extension. Mixes the
//  two iOS APIs that were each verified empirically inside an
//  `NEPacketTunnelProvider` sandbox:
//
//    - POSIX UDP sockets for the multicast HELLO discovery channel.
//      `NWConnectionGroup` with `NWMulticastGroup` reports `ready`
//      but never delivers inbound packets to the receive handler in
//      this sandbox; an explicit `setsockopt(IPV6_JOIN_GROUP)` on a
//      raw socket does receive them.
//    - `NWListener` for the unicast data port. POSIX `bind` to a
//      link-local IPv6 + port succeeds but iOS routes incoming
//      packets to the system networking stack rather than our
//      socket; `NWListener` on the same port does receive them.
//    - `NWConnection` per peer for outbound unicast data. The
//      Network framework handles per-peer routing on the Wi-Fi
//      interface correctly.
//
//  Wire-compatible with reticulum-swift's `AutoInterface`:
//    - multicast group: `ff12:0:…` from
//      `AutoInterfaceConstants.multicastAddress(for:)`
//    - HELLO beacons: 32-byte SHA-256 from
//      `AutoInterfaceConstants.discoveryToken(groupId:address:)`
//    - data: plain UDP datagrams on `defaultDataPort` (42671)
//

import Foundation
import Network
import Darwin
@preconcurrency import ReticulumSwift

final class ExtensionAutoBridge: @unchecked Sendable {

    // MARK: - Dependencies

    private let frameQueue: SharedFrameQueue
    private let postNotif: () -> Void

    // MARK: - State

    private(set) var groupId: String?
    private var multicastAddress: String = ""
    private var discoveryPort: UInt16 = AutoInterfaceConstants.defaultDiscoveryPort
    private var dataPort: UInt16 = AutoInterfaceConstants.defaultDataPort

    /// POSIX UDP sockets keyed by Wi-Fi interface name. Each socket
    /// is joined to the multicast group on its interface; receive
    /// loop reads HELLOs via `recvfrom`. Sends fan out via
    /// `sendto` to the multicast endpoint.
    private var multicastSockets: [String: Int32] = [:]

    /// `ifname → ifIndex` for `IPV6_JOIN_GROUP` and scope id when
    /// converting endpoints into `sockaddr_in6`.
    private var multicastInterfaces: [String: UInt32] = [:]

    /// Per-interface receive task spinning on `poll() / recvfrom`.
    private var multicastReceiveTasks: [String: Task<Void, Never>] = [:]

    /// Outbound `NWConnection` to the multicast group endpoint.
    /// POSIX `sendto` from the multicast socket fails with
    /// `ENETUNREACH` in the extension sandbox even though POSIX
    /// `IPV6_JOIN_GROUP` + `recvfrom` works fine on the same
    /// socket. `NWConnection` to the multicast destination goes out
    /// cleanly — Apple's framework owns its own routing decisions.
    private var multicastSender: NWConnection?

    /// `NWListener` on the data port. `NWConnection` per peer.
    private var dataListener: NWListener?
    private var peerConnections: [String: NWConnection] = [:]
    private var peerLastHeard: [String: Date] = [:]

    /// Our own link-local IPv6 addresses — used to filter our own
    /// multicast echoes and to compute the discovery tokens we
    /// announce on each interface.
    private var ownAddresses: Set<String> = []

    private var announceTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

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
        let interfaces = Self.discoverWifiInterfaces()
        for ifInfo in interfaces {
            multicastInterfaces[ifInfo.name] = ifInfo.index
        }

        ExtensionDiagLog.log("[EXT/Auto] starting groupId=\(groupId) mcast=\(multicastAddress) own=\(ownAddresses) ifaces=\(interfaces.map(\.name))")

        for ifInfo in interfaces {
            do {
                let fd = try setupMulticastSocket(interfaceIndex: ifInfo.index)
                multicastSockets[ifInfo.name] = fd
                startMulticastReceiveLoop(ifname: ifInfo.name, fd: fd)
                ExtensionDiagLog.log("[EXT/Auto] multicast socket bound on \(ifInfo.name) idx=\(ifInfo.index)")
            } catch {
                ExtensionDiagLog.log("[EXT/Auto] multicast socket setup failed on \(ifInfo.name): \(error)")
            }
        }

        startMulticastSender()
        startDataListener()
        startAnnounceLoop()
        startMaintenanceLoop()
    }

    /// Open an `NWConnection` aimed at the multicast group so we can
    /// `send()` HELLOs through Apple's framework — empirically the
    /// only outbound path that doesn't fail with `ENETUNREACH` from
    /// inside an `NEPacketTunnelProvider` sandbox.
    private func startMulticastSender() {
        guard let port = NWEndpoint.Port(rawValue: discoveryPort),
              let host = IPv6Address(multicastAddress) else { return }
        let conn = NWConnection(host: .ipv6(host), port: port, using: .udp)
        conn.stateUpdateHandler = { state in
            ExtensionDiagLog.log("[EXT/Auto] mcast sender state: \(state)")
        }
        conn.start(queue: .global(qos: .utility))
        self.multicastSender = conn
    }

    func stop() {
        announceTask?.cancel()
        announceTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil

        for (_, task) in multicastReceiveTasks { task.cancel() }
        multicastReceiveTasks.removeAll()

        multicastSender?.cancel()
        multicastSender = nil

        for (_, fd) in multicastSockets { Darwin.close(fd) }
        multicastSockets.removeAll()
        multicastInterfaces.removeAll()

        dataListener?.cancel()
        dataListener = nil

        stateQueue.sync {
            for (_, conn) in peerConnections { conn.cancel() }
            peerConnections.removeAll()
            peerLastHeard.removeAll()
            ownAddresses.removeAll()
        }
        groupId = nil
    }

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

    // MARK: - Multicast (POSIX)

    private func setupMulticastSocket(interfaceIndex: UInt32) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        // Reuse so multiple processes / multiple sockets don't
        // collide on the multicast port.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Multicast send egress interface.
        var ifIdx: UInt32 = interfaceIndex
        setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &ifIdx, socklen_t(MemoryLayout<UInt32>.size))

        // Loopback so our own HELLOs come back to us — lets us
        // filter our own echoes by `ownAddresses` and confirms the
        // socket is alive.
        var loop: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<Int32>.size))

        // Join the multicast group on this interface.
        var mreq = ipv6_mreq()
        var grpAddr = in6_addr()
        _ = multicastAddress.withCString { cstr in
            inet_pton(AF_INET6, cstr, &grpAddr)
        }
        mreq.ipv6mr_multiaddr = grpAddr
        mreq.ipv6mr_interface = interfaceIndex
        let joinResult = setsockopt(fd, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq, socklen_t(MemoryLayout<ipv6_mreq>.size))
        if joinResult != 0 {
            let err = errno
            Darwin.close(fd)
            ExtensionDiagLog.log("[EXT/Auto] IPV6_JOIN_GROUP failed errno=\(err)")
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        // Bind to the discovery port on the wildcard address.
        var sin6 = sockaddr_in6()
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = discoveryPort.bigEndian
        sin6.sin6_addr = in6addr_any
        let bindResult = withUnsafePointer(to: &sin6) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if bindResult != 0 {
            let err = errno
            Darwin.close(fd)
            ExtensionDiagLog.log("[EXT/Auto] mcast bind failed errno=\(err)")
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        // Non-blocking so our recv loop can poll cooperatively.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        return fd
    }

    private func startMulticastReceiveLoop(ifname: String, fd: Int32) {
        let task = Task.detached { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1024)
            while !Task.isCancelled {
                var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pollFd, 1, 500)
                if Task.isCancelled { return }
                guard pollResult > 0 else { continue }

                var src = sockaddr_in6()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let n = buf.withUnsafeMutableBufferPointer { bufPtr -> Int in
                    withUnsafeMutablePointer(to: &src) { srcPtr in
                        srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                            recvfrom(fd, bufPtr.baseAddress, bufPtr.count, 0, saPtr, &srcLen)
                        }
                    }
                }
                guard n > 0 else { continue }

                let data = Data(buf[0..<n])
                var addrBuf = [Int8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &src.sin6_addr, &addrBuf, socklen_t(INET6_ADDRSTRLEN))
                let sourceAddress = String(cString: addrBuf)

                self?.handleHello(token: data, sourceAddress: sourceAddress, ifname: ifname)
            }
        }
        multicastReceiveTasks[ifname] = task
    }

    private func handleHello(token: Data, sourceAddress: String, ifname: String) {
        guard let groupId else { return }
        guard token.count == 32 else { return }
        let groupBytes = groupId.data(using: .utf8) ?? Data()
        let expected = AutoInterfaceConstants.discoveryToken(
            groupId: groupBytes,
            address: sourceAddress
        )
        guard token == expected else { return }
        if ownAddresses.contains(sourceAddress) { return }

        let newConn: NWConnection? = stateQueue.sync {
            peerLastHeard[sourceAddress] = Date()
            if peerConnections[sourceAddress] != nil { return nil }
            guard let port = NWEndpoint.Port(rawValue: dataPort),
                  let host = IPv6Address(sourceAddress) else { return nil }
            let conn = NWConnection(host: .ipv6(host), port: port, using: .udp)
            peerConnections[sourceAddress] = conn
            return conn
        }

        if let conn = newConn {
            ExtensionDiagLog.log("[EXT/Auto] peer added: \(sourceAddress) (via \(ifname))")
            conn.stateUpdateHandler = { [weak conn] state in
                ExtensionDiagLog.log("[EXT/Auto] peer conn \(sourceAddress) state: \(state)")
                if state == .ready, let path = conn?.currentPath {
                    ExtensionDiagLog.log("[EXT/Auto] peer conn \(sourceAddress) path: status=\(path.status) iface=\(path.availableInterfaces.map { $0.name }) localEndpoint=\(path.localEndpoint?.debugDescription ?? "?")")
                }
            }
            conn.start(queue: .global(qos: .utility))
            // Reverse unicast peering: send a HELLO directly to the
            // peer's `unicastDiscoveryPort` (discoveryPort+1) so it
            // adds us even though outbound multicast is broken in
            // the extension sandbox. Mirrors reticulum-swift's
            // `sendReversePeering`.
            sendReversePeering(to: sourceAddress)
        }
    }

    /// Send a 32-byte HELLO token to the peer's
    /// `unicastDiscoveryPort` so the peer learns we exist even
    /// when our outbound multicast fails. Reticulum's AutoInterface
    /// listens on `discoveryPort + 1` (29717) for these.
    private func sendReversePeering(to address: String) {
        guard let groupId else { return }
        let groupBytes = groupId.data(using: .utf8) ?? Data()
        guard let port = NWEndpoint.Port(rawValue: discoveryPort + 1),
              let host = IPv6Address(address) else { return }

        for ownAddr in ownAddresses {
            let token = AutoInterfaceConstants.discoveryToken(
                groupId: groupBytes,
                address: ownAddr
            )
            let conn = NWConnection(host: .ipv6(host), port: port, using: .udp)
            conn.start(queue: .global(qos: .utility))
            conn.send(content: token, completion: .contentProcessed { error in
                if let error {
                    ExtensionDiagLog.log("[EXT/Auto] reverse peering to \(address) failed: \(error)")
                } else {
                    ExtensionDiagLog.log("[EXT/Auto] reverse peering sent to \(address) (\(token.count)B)")
                }
                conn.cancel()
            })
        }
    }

    // MARK: - Inbound unicast (NWListener)

    private func startDataListener() {
        guard let port = NWEndpoint.Port(rawValue: dataPort) else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: .udp, on: port)
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
                ExtensionDiagLog.log("[EXT/Auto] RX \(content.count)B")

                #if DEBUG
                // Diagnostic: send a synthetic response on the same
                // connection. iOS might block *initiating* outbound
                // flows but allow responses on accepted ones; if so,
                // a Mac listener that sent a probe will receive this
                // back, confirming bidirectional via established
                // connections.
                //
                // Gated behind `#if DEBUG` so production builds don't
                // flood every Auto peer with synthetic ASCII payloads
                // that aren't valid Reticulum frames.
                let probe = "ext-rx-ack-\(Date().timeIntervalSince1970)".data(using: .utf8)!
                connection?.send(content: probe, completion: .contentProcessed { error in
                    if let error {
                        ExtensionDiagLog.log("[EXT/Auto] RX-ack send failed: \(error)")
                    } else {
                        ExtensionDiagLog.log("[EXT/Auto] RX-ack sent (\(probe.count)B) on accepted conn")
                    }
                })
                #endif
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
            if let conn = connection {
                self?.receiveLoop(conn)
            }
        }
    }

    // MARK: - Periodic loops

    private func startAnnounceLoop() {
        announceTask = Task { [weak self] in
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

    /// Send HELLO multicasts via the NWConnection-backed sender —
    /// POSIX `sendto` to the multicast group hits `ENETUNREACH` in
    /// the extension sandbox.
    private func sendHellos() {
        guard let groupId else { return }
        guard let sender = multicastSender else {
            ExtensionDiagLog.log("[EXT/Auto] sendHellos: no multicast sender")
            return
        }
        let groupBytes = groupId.data(using: .utf8) ?? Data()
        for ownAddr in ownAddresses {
            let token = AutoInterfaceConstants.discoveryToken(
                groupId: groupBytes,
                address: ownAddr
            )
            sender.send(content: token, completion: .contentProcessed { error in
                if let error {
                    ExtensionDiagLog.log("[EXT/Auto] HELLO send failed for \(ownAddr): \(error)")
                } else {
                    ExtensionDiagLog.log("[EXT/Auto] HELLO sent for \(ownAddr) (\(token.count)B)")
                }
            })
        }
    }

    private func startMaintenanceLoop() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AutoInterfaceConstants.peerJobInterval))
                self?.expireStalePeers()
                self?.refreshReversePeering()
            }
        }
    }

    /// Periodically re-send reverse unicast peering so peers don't
    /// expire us — they only keep us in their peer table for
    /// `peeringTimeout`. We can't rely on outbound multicast to
    /// re-announce ourselves, so push directly via unicast.
    private func refreshReversePeering() {
        let addrs: [String] = stateQueue.sync {
            Array(peerConnections.keys)
        }
        for addr in addrs {
            sendReversePeering(to: addr)
        }
    }

    private func expireStalePeers() {
        let now = Date()
        let timeout = AutoInterfaceConstants.peeringTimeout
        let stale: [(addr: String, conn: NWConnection?)] = stateQueue.sync {
            let staleAddrs = peerLastHeard.compactMap { addr, lastHeard in
                now.timeIntervalSince(lastHeard) > timeout ? addr : nil
            }
            let result = staleAddrs.map { addr -> (String, NWConnection?) in
                let conn = peerConnections.removeValue(forKey: addr)
                peerLastHeard.removeValue(forKey: addr)
                return (addr, conn)
            }
            return result
        }
        for (addr, conn) in stale {
            conn?.cancel()
            ExtensionDiagLog.log("[EXT/Auto] peer expired: \(addr)")
        }
    }

    // MARK: - Helpers

    /// All Wi-Fi-shaped (`en*`) interfaces that have a link-local
    /// IPv6 address. Used to pick which interface(s) we open
    /// multicast sockets on.
    static func discoverWifiInterfaces() -> [(name: String, index: UInt32)] {
        var seen = Set<String>()
        var results: [(String, UInt32)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return results }
        defer { freeifaddrs(ifap) }
        var ptr = ifap
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let name = String(cString: p.pointee.ifa_name)
            if !name.hasPrefix("en") { continue }
            if seen.contains(name) { continue }

            // Only adopt interfaces that actually have a link-local
            // IPv6 we can announce as.
            guard let saPtr = p.pointee.ifa_addr,
                  saPtr.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            let sin6 = saPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let bytes = withUnsafePointer(to: sin6.sin6_addr) { ptr in
                UnsafeRawPointer(ptr).load(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)
            }
            guard bytes.0 == 0xfe, (bytes.1 & 0xc0) == 0x80 else { continue }

            seen.insert(name)
            results.append((name, if_nametoindex(name)))
        }
        return results
    }

    /// All link-local IPv6 addresses on this device (`fe80::/10` on
    /// every interface — not just `en*`). Used for filtering own
    /// multicast echoes; we need to include `awdl0`, `utun*`, etc.
    /// because IPv6 multicast loopback delivers our own packets back
    /// from those interfaces' addresses, and missing any of them
    /// would create spurious "peers" that are really ourselves.
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
            let sin6 = saPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let bytes = withUnsafePointer(to: sin6.sin6_addr) { ptr in
                UnsafeRawPointer(ptr).load(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)
            }
            guard bytes.0 == 0xfe, (bytes.1 & 0xc0) == 0x80 else { continue }

            var buf = [Int8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var addrCopy = sin6.sin6_addr
            inet_ntop(AF_INET6, &addrCopy, &buf, socklen_t(INET6_ADDRSTRLEN))
            addresses.insert(String(cString: buf))
        }
        return addresses
    }
}
