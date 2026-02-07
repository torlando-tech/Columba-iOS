//
//  InterfaceRepository.swift
//  ColumbaApp
//
//  Repository for managing Reticulum network interface configurations.
//  Persists interface settings to UserDefaults with JSON encoding.
//

import Foundation
import ReticulumSwift

// MARK: - Interface Entity

/// Represents a configured Reticulum network interface.
///
/// Mirrors the Android Columba InterfaceEntity structure for consistency.
/// Stored as JSON in UserDefaults.
public struct InterfaceEntity: Codable, Identifiable, Equatable, Sendable {
    /// Unique identifier for this interface
    public let id: String

    /// User-friendly name (e.g., "Home Relay", "Mobile TCP")
    public var name: String

    /// Interface type identifier
    public var type: InterfaceType

    /// Whether this interface is enabled
    public var enabled: Bool

    /// Interface mode controlling announce propagation
    public var mode: InterfaceMode

    /// Type-specific configuration
    public var config: InterfaceTypeConfig

    /// Display order in the list (lower = first)
    public var displayOrder: Int

    /// Creation timestamp
    public let createdAt: Date

    /// Last modified timestamp
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        type: InterfaceType,
        enabled: Bool = true,
        mode: InterfaceMode = .full,
        config: InterfaceTypeConfig,
        displayOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.mode = mode
        self.config = config
        self.displayOrder = displayOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Interface Type

/// Type of network interface.
public enum InterfaceType: String, Codable, Sendable, CaseIterable {
    case tcpClient = "TCPClient"
    case tcpServer = "TCPServer"
    case autoInterface = "AutoInterface"
    case ble = "BLE"
    case rnode = "RNode"

    public var displayName: String {
        switch self {
        case .tcpClient: return "TCP Client"
        case .tcpServer: return "TCP Server"
        case .autoInterface: return "Auto Discovery"
        case .ble: return "Bluetooth LE"
        case .rnode: return "RNode LoRa"
        }
    }

    public var description: String {
        switch self {
        case .tcpClient: return "Connect to a remote Reticulum transport node"
        case .tcpServer: return "Accept incoming connections from other nodes"
        case .autoInterface: return "Automatically discover peers on local network"
        case .ble: return "Peer-to-peer networking over Bluetooth LE"
        case .rnode: return "Connect to RNode hardware via Bluetooth"
        }
    }

    public var icon: String {
        switch self {
        case .tcpClient: return "arrow.up.forward.circle"
        case .tcpServer: return "arrow.down.backward.circle"
        case .autoInterface: return "antenna.radiowaves.left.and.right"
        case .ble: return "wave.3.right"
        case .rnode: return "radio"
        }
    }
}

// MARK: - Interface Type Config

/// Type-specific configuration parameters.
public enum InterfaceTypeConfig: Codable, Equatable, Sendable {
    case tcpClient(TCPClientConfig)
    case tcpServer(TCPServerConfig)
    case autoInterface(AutoInterfaceConfig)
    case ble(BLEConfig)
    case rnode(RNodeConfig)

    private enum CodingKeys: String, CodingKey {
        case type
        case config
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "tcpClient":
            let config = try container.decode(TCPClientConfig.self, forKey: .config)
            self = .tcpClient(config)
        case "tcpServer":
            let config = try container.decode(TCPServerConfig.self, forKey: .config)
            self = .tcpServer(config)
        case "autoInterface":
            let config = try container.decode(AutoInterfaceConfig.self, forKey: .config)
            self = .autoInterface(config)
        case "ble":
            let config = try container.decode(BLEConfig.self, forKey: .config)
            self = .ble(config)
        case "rnode":
            let config = try container.decode(RNodeConfig.self, forKey: .config)
            self = .rnode(config)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown config type: \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .tcpClient(let config):
            try container.encode("tcpClient", forKey: .type)
            try container.encode(config, forKey: .config)
        case .tcpServer(let config):
            try container.encode("tcpServer", forKey: .type)
            try container.encode(config, forKey: .config)
        case .autoInterface(let config):
            try container.encode("autoInterface", forKey: .type)
            try container.encode(config, forKey: .config)
        case .ble(let config):
            try container.encode("ble", forKey: .type)
            try container.encode(config, forKey: .config)
        case .rnode(let config):
            try container.encode("rnode", forKey: .type)
            try container.encode(config, forKey: .config)
        }
    }
}

// MARK: - TCP Client Config

/// Configuration for TCP client interface.
public struct TCPClientConfig: Codable, Equatable, Sendable {
    /// Target host address (IP or hostname)
    public var targetHost: String

    /// Target port number
    public var targetPort: UInt16

    /// Optional network name (IFAC)
    public var networkName: String?

    /// Optional passphrase (IFAC)
    public var passphrase: String?

    public init(
        targetHost: String,
        targetPort: UInt16 = 4242,
        networkName: String? = nil,
        passphrase: String? = nil
    ) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.networkName = networkName
        self.passphrase = passphrase
    }
}

// MARK: - TCP Server Config

/// Configuration for TCP server interface.
public struct TCPServerConfig: Codable, Equatable, Sendable {
    /// IP address to bind to
    public var listenIp: String

    /// Port to listen on
    public var listenPort: UInt16

    public init(
        listenIp: String = "0.0.0.0",
        listenPort: UInt16 = 4242
    ) {
        self.listenIp = listenIp
        self.listenPort = listenPort
    }
}

// MARK: - Auto Interface Config

/// Configuration for auto-discovery interface.
public struct AutoInterfaceConfig: Codable, Equatable, Sendable {
    /// Optional group ID for network segmentation
    public var groupId: String?

    /// Discovery scope
    public var discoveryScope: String

    /// Discovery port (nil = default 29716)
    public var discoveryPort: UInt16?

    /// Data port (nil = default 42671)
    public var dataPort: UInt16?

    public init(
        groupId: String? = nil,
        discoveryScope: String = "link",
        discoveryPort: UInt16? = nil,
        dataPort: UInt16? = nil
    ) {
        self.groupId = groupId
        self.discoveryScope = discoveryScope
        self.discoveryPort = discoveryPort
        self.dataPort = dataPort
    }
}

// MARK: - BLE Mesh Config

/// Configuration for BLE mesh interface.
public struct BLEConfig: Codable, Equatable, Sendable {
    /// Whether to enable advertising (GATT server)
    public var advertise: Bool

    /// Whether to enable scanning (GATT client)
    public var scan: Bool

    public init(
        advertise: Bool = true,
        scan: Bool = true
    ) {
        self.advertise = advertise
        self.scan = scan
    }
}

// MARK: - RNode Config

/// Configuration for RNode LoRa interface.
///
/// Stores BLE device name alongside all radio parameters needed
/// for RNodeInterface. Use `toRadioConfig()` to convert to the
/// transport-layer RadioConfig for RNodeInterface.configureRadio().
public struct RNodeConfig: Codable, Equatable, Sendable {
    /// BLE device name (e.g., "RNode_A9")
    public var deviceName: String

    /// Radio frequency in Hz (e.g., 915_000_000 for 915 MHz)
    public var frequency: UInt32

    /// Radio bandwidth in Hz (e.g., 125_000)
    public var bandwidth: UInt32

    /// TX power in dBm (2-22)
    public var txPower: UInt8

    /// LoRa spreading factor (7-12)
    public var spreadingFactor: UInt8

    /// LoRa coding rate (5-8)
    public var codingRate: UInt8

    /// Short-term airtime lock percentage (optional, 0-100%)
    public var stAlock: Float?

    /// Long-term airtime lock percentage (optional, 0-100%)
    public var ltAlock: Float?

    /// Convert to transport-layer RadioConfig for RNodeInterface.
    public func toRadioConfig() -> RadioConfig {
        RadioConfig(
            frequency: frequency,
            bandwidth: bandwidth,
            txPower: txPower,
            spreadingFactor: spreadingFactor,
            codingRate: codingRate,
            stAlock: stAlock,
            ltAlock: ltAlock
        )
    }

    /// Default RNode config for US 915 MHz ISM band.
    public static var defaultUS915: RNodeConfig {
        RNodeConfig(
            deviceName: "",
            frequency: 915_000_000,
            bandwidth: 125_000,
            txPower: 17,
            spreadingFactor: 7,
            codingRate: 5,
            stAlock: nil,
            ltAlock: nil
        )
    }

    public init(
        deviceName: String,
        frequency: UInt32,
        bandwidth: UInt32,
        txPower: UInt8,
        spreadingFactor: UInt8,
        codingRate: UInt8,
        stAlock: Float? = nil,
        ltAlock: Float? = nil
    ) {
        self.deviceName = deviceName
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.txPower = txPower
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.stAlock = stAlock
        self.ltAlock = ltAlock
    }
}

// MARK: - Interface Mode

/// Interface mode controlling announce propagation.
/// Matches ReticulumSwift.InterfaceMode for consistency.
public enum InterfaceMode: String, Codable, Sendable, Equatable, CaseIterable {
    case full = "full"
    case gateway = "gateway"
    case accessPoint = "access_point"
    case roaming = "roaming"
    case boundary = "boundary"

    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .gateway: return "Gateway"
        case .accessPoint: return "Access Point"
        case .roaming: return "Roaming"
        case .boundary: return "Boundary"
        }
    }

    public var description: String {
        switch self {
        case .full: return "All features enabled"
        case .gateway: return "Path discovery for others"
        case .accessPoint: return "Quiet unless active"
        case .roaming: return "Mobile relative to others"
        case .boundary: return "Links dissimilar segments"
        }
    }
}

// MARK: - Interface Status

/// Runtime status of an interface.
public enum InterfaceStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error

    public var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting: return "Retrying..."
        case .error: return "Unreachable"
        }
    }

    public var color: String {
        switch self {
        case .disconnected: return "gray"
        case .connecting: return "orange"
        case .connected: return "green"
        case .reconnecting: return "orange"
        case .error: return "red"
        }
    }
}

// MARK: - Interface Repository

/// Repository for CRUD operations on interface configurations.
///
/// Uses UserDefaults for persistence. Thread-safe via actor isolation.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class InterfaceRepository: @unchecked Sendable {

    // MARK: - Constants

    private let storageKey = "com.columba.interfaces"
    private let defaults: UserDefaults

    // MARK: - Published State

    /// All stored interfaces
    public private(set) var interfaces: [InterfaceEntity] = []

    /// Number of enabled interfaces
    public var enabledCount: Int {
        interfaces.filter { $0.enabled }.count
    }

    /// Total number of interfaces
    public var totalCount: Int {
        interfaces.count
    }

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        loadInterfaces()
    }

    // MARK: - CRUD Operations

    /// Load all interfaces from storage.
    public func loadInterfaces() {
        guard let data = defaults.data(forKey: storageKey) else {
            interfaces = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([InterfaceEntity].self, from: data)
            interfaces = decoded.sorted { $0.displayOrder < $1.displayOrder }
            print("[INTERFACE_REPO] Loaded \(interfaces.count) interfaces")
        } catch {
            print("[INTERFACE_REPO] Failed to decode interfaces: \(error)")
            interfaces = []
        }
    }

    /// Save all interfaces to storage.
    private func saveInterfaces() {
        do {
            let data = try JSONEncoder().encode(interfaces)
            defaults.set(data, forKey: storageKey)
            print("[INTERFACE_REPO] Saved \(interfaces.count) interfaces")
        } catch {
            print("[INTERFACE_REPO] Failed to encode interfaces: \(error)")
        }
    }

    /// Add a new interface.
    public func addInterface(_ interface: InterfaceEntity) {
        var newInterface = interface
        newInterface.displayOrder = (interfaces.map { $0.displayOrder }.max() ?? -1) + 1
        interfaces.append(newInterface)
        saveInterfaces()
        print("[INTERFACE_REPO] Added interface: \(newInterface.name)")
    }

    /// Update an existing interface.
    public func updateInterface(_ interface: InterfaceEntity) {
        guard let index = interfaces.firstIndex(where: { $0.id == interface.id }) else {
            print("[INTERFACE_REPO] Interface not found for update: \(interface.id)")
            return
        }

        var updated = interface
        updated.updatedAt = Date()
        interfaces[index] = updated
        saveInterfaces()
        print("[INTERFACE_REPO] Updated interface: \(updated.name)")
    }

    /// Delete an interface by ID.
    public func deleteInterface(id: String) {
        interfaces.removeAll { $0.id == id }
        saveInterfaces()
        print("[INTERFACE_REPO] Deleted interface: \(id)")
    }

    /// Toggle interface enabled state.
    public func toggleInterface(id: String, enabled: Bool) {
        guard let index = interfaces.firstIndex(where: { $0.id == id }) else {
            return
        }

        interfaces[index].enabled = enabled
        interfaces[index].updatedAt = Date()
        saveInterfaces()
        print("[INTERFACE_REPO] Toggled interface \(id): enabled=\(enabled)")
    }

    /// Get interface by ID.
    public func getInterface(id: String) -> InterfaceEntity? {
        interfaces.first { $0.id == id }
    }

    /// Get all enabled interfaces.
    public func getEnabledInterfaces() -> [InterfaceEntity] {
        interfaces.filter { $0.enabled }
    }

}
