//
//  PacketTunnelProvider.swift
//  ColumbaNetworkExtension
//
//  Minimal NEPacketTunnelProvider that keeps TCP and AutoInterface NWConnections
//  alive while the main app is backgrounded. No Reticulum protocol knowledge,
//  no crypto, no LXMF parsing — just raw frame forwarding via a shared queue file.
//
//  Inbound: TCP/Auto data → HDLC deframe (TCP only) → SharedFrameQueue → Darwin notif
//  Outbound: App sends via sendProviderMessage → extension sends on NWConnection
//

import Foundation
import Network
import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Constants

    private static let appGroupId = "group.network.columba.app"
    private static let packetReadyNotification = "network.columba.packetReady"
    private static let interfacesKey = "com.columba.interfaces"

    // MARK: - Properties

    private var tcpConnection: NWConnection?
    private var autoListener: NWConnectionGroup?
    private lazy var frameQueue = SharedFrameQueue(appGroupIdentifier: Self.appGroupId)

    /// HDLC receive buffer for TCP stream framing
    private var tcpReceiveBuffer = Data()

    /// HDLC constants
    private static let FLAG: UInt8 = 0x7E
    private static let ESC: UInt8 = 0x7D
    private static let ESC_MASK: UInt8 = 0x20

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[EXT] startTunnel called")

        // Read interface configs from shared UserDefaults
        let defaults = UserDefaults(suiteName: Self.appGroupId) ?? .standard
        let configs = loadInterfaceConfigs(from: defaults)

        // Start TCP connection if configured
        if let tcp = configs.tcp {
            startTCPConnection(host: tcp.host, port: tcp.port)
        }

        // Start AutoInterface multicast listener if configured
        if let groupId = configs.autoGroupId {
            startAutoListener(groupId: groupId)
        }

        // Set up dummy tunnel settings (required by NEPacketTunnelProvider)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["169.254.1.1"], subnetMasks: ["255.255.255.255"])
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { error in
            if let error {
                NSLog("[EXT] Failed to set tunnel settings: \(error)")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[EXT] stopTunnel reason=\(reason.rawValue)")
        tcpConnection?.cancel()
        tcpConnection = nil
        autoListener?.cancel()
        autoListener = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Format: [1-byte interface tag][N-byte HDLC-framed data]
        guard messageData.count >= 2 else {
            completionHandler?(nil)
            return
        }

        let interfaceTag = messageData[0]
        let frameData = messageData.dropFirst()

        switch interfaceTag {
        case FrameInterfaceTag.tcp.rawValue:
            tcpConnection?.send(content: frameData, completion: .contentProcessed { error in
                if let error {
                    NSLog("[EXT] TCP send error: \(error)")
                }
            })
        case FrameInterfaceTag.auto.rawValue:
            // Auto frames are sent as UDP datagrams via the connection group
            autoListener?.send(content: frameData) { error in
                if let error {
                    NSLog("[EXT] Auto send error: \(error)")
                }
            }
        default:
            NSLog("[EXT] Unknown interface tag: \(interfaceTag)")
        }

        completionHandler?(nil)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        NSLog("[EXT] sleep")
        completionHandler()
    }

    override func wake() {
        NSLog("[EXT] wake")
        // Reconnect if needed
        if tcpConnection?.state == .cancelled || tcpConnection?.state == .failed(NWError.posix(.ECONNRESET)) {
            let defaults = UserDefaults(suiteName: Self.appGroupId) ?? .standard
            let configs = loadInterfaceConfigs(from: defaults)
            if let tcp = configs.tcp {
                startTCPConnection(host: tcp.host, port: tcp.port)
            }
        }
    }

    // MARK: - TCP Connection

    private func startTCPConnection(host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        params.requiredInterfaceType = .other // Allow any interface

        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        self.tcpConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            NSLog("[EXT] TCP state: \(state)")
            switch state {
            case .ready:
                self?.receiveTCPData()
            case .failed(let error):
                NSLog("[EXT] TCP failed: \(error), reconnecting in 5s")
                self?.tcpConnection?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.startTCPConnection(host: host, port: port)
                }
            case .waiting(let error):
                NSLog("[EXT] TCP waiting: \(error)")
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    private func receiveTCPData() {
        tcpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self?.handleTCPData(data)
            }

            if isComplete {
                NSLog("[EXT] TCP connection complete (EOF)")
                return
            }

            if let error {
                NSLog("[EXT] TCP receive error: \(error)")
                return
            }

            // Continue receiving
            self?.receiveTCPData()
        }
    }

    /// Buffer TCP data and extract HDLC frames.
    private func handleTCPData(_ data: Data) {
        tcpReceiveBuffer.append(data)

        // Extract complete HDLC frames
        let frames = extractHDLCFrames(from: &tcpReceiveBuffer)

        for frame in frames {
            frameQueue.append(frame: frame, interfaceTag: FrameInterfaceTag.tcp.rawValue)
        }

        if !frames.isEmpty {
            postDarwinNotification()
        }
    }

    // MARK: - AutoInterface Multicast Listener

    private func startAutoListener(groupId: String) {
        // AutoInterface uses link-local multicast on a well-known group/port
        // The discovery and data ports match ReticulumSwift AutoInterface defaults
        let discoveryPort: UInt16 = 29716
        let multicastGroup: NWMulticastGroup
        do {
            multicastGroup = try NWMulticastGroup(for: [
                .hostPort(host: .ipv6(IPv6Address("ff02::1")!), port: NWEndpoint.Port(rawValue: discoveryPort)!)
            ])
        } catch {
            NSLog("[EXT] Failed to create multicast group: %@", "\(error)")
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .other

        let group = NWConnectionGroup(with: multicastGroup, using: params)
        self.autoListener = group

        group.stateUpdateHandler = { state in
            NSLog("[EXT] Auto multicast state: \(state)")
        }

        group.setReceiveHandler(maximumMessageSize: 2048, rejectOversizedMessages: false) { [weak self] message, content, isComplete in
            guard let content, !content.isEmpty else { return }

            // Auto frames are complete UDP datagrams (no HDLC framing needed)
            self?.frameQueue.append(frame: content, interfaceTag: FrameInterfaceTag.auto.rawValue)
            self?.postDarwinNotification()
        }

        group.start(queue: .main)
    }

    // MARK: - HDLC Frame Extraction

    /// Extract complete HDLC frames from a TCP buffer.
    /// Mirrors the logic in ReticulumSwift/Protocol/HDLC.swift.
    private func extractHDLCFrames(from buffer: inout Data) -> [Data] {
        var frames: [Data] = []

        while true {
            guard let startIdx = buffer.firstIndex(of: Self.FLAG) else { break }

            let searchStart = buffer.index(after: startIdx)
            guard searchStart < buffer.endIndex,
                  let endIdx = buffer[searchStart...].firstIndex(of: Self.FLAG) else { break }

            let frameContent = buffer[(buffer.index(after: startIdx))..<endIdx]
            buffer.removeSubrange(buffer.startIndex...endIdx)

            if frameContent.isEmpty { continue }

            if let unescaped = hdlcUnescape(Data(frameContent)) {
                frames.append(unescaped)
            }
        }

        return frames
    }

    /// Unescape HDLC frame content.
    private func hdlcUnescape(_ data: Data) -> Data? {
        var result = Data()
        result.reserveCapacity(data.count)
        var escapeNext = false

        for byte in data {
            if escapeNext {
                result.append(byte ^ Self.ESC_MASK)
                escapeNext = false
            } else if byte == Self.ESC {
                escapeNext = true
            } else {
                result.append(byte)
            }
        }

        return escapeNext ? nil : result
    }

    // MARK: - Darwin Notifications

    private func postDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(Self.packetReadyNotification as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Config Loading

    private struct InterfaceConfigs {
        var tcp: (host: String, port: UInt16)?
        var autoGroupId: String?
    }

    /// Load interface configs from shared UserDefaults.
    /// Parses the same JSON format as InterfaceRepository.
    private func loadInterfaceConfigs(from defaults: UserDefaults) -> InterfaceConfigs {
        var result = InterfaceConfigs()

        guard let data = defaults.data(forKey: Self.interfacesKey) else {
            NSLog("[EXT] No interface configs found")
            return result
        }

        // Parse the JSON array — we only need type + config fields
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            NSLog("[EXT] Failed to parse interface configs")
            return result
        }

        for entity in array {
            guard let enabled = entity["enabled"] as? Bool, enabled,
                  let configWrapper = entity["config"] as? [String: Any],
                  let type = configWrapper["type"] as? String,
                  let config = configWrapper["config"] as? [String: Any] else {
                continue
            }

            switch type {
            case "tcpClient":
                if let host = config["targetHost"] as? String,
                   let port = config["targetPort"] as? Int {
                    result.tcp = (host: host, port: UInt16(port))
                    NSLog("[EXT] Found TCP config: \(host):\(port)")
                }
            case "autoInterface":
                let groupId = config["groupId"] as? String ?? "reticulum"
                result.autoGroupId = groupId
                NSLog("[EXT] Found Auto config: groupId=\(groupId)")
            default:
                break
            }
        }

        return result
    }
}
