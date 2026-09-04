import Foundation

/// Information about an interface discovered via RNS 1.1.x interface discovery.
///
/// RNS 1.1.0+ interface discovery provides detailed information about
/// interfaces announced by other nodes on the network, including TCP servers,
/// RNodes, and other interface types.
///
/// Decoding is deliberately lenient (mirrors the Android
/// `DiscoveredInterface.parseItem` semantics): missing keys fall back to
/// defaults or `nil`, RNS may emit integral values as JSON floats (decoded
/// and rounded), and empty strings decode as `nil` for the optional string
/// fields.
public struct DiscoveredInterface: Codable, Equatable, Sendable, Identifiable {
    // MARK: - Stored properties

    /// Interface name.
    public let name: String
    /// Interface type, e.g. "TCPServerInterface", "RNodeInterface".
    public let type: String
    /// "available" | "unknown" | "stale".
    public let status: String
    /// Transport identity hash.
    public let transportId: String?
    /// Network identity hash.
    public let networkId: String?
    /// 1000 = available, 100 = unknown, 0 = stale.
    public let statusCode: Int?
    /// Unix timestamp in seconds (RNS may emit a float); 0 = never heard.
    public let lastHeard: Double
    /// Number of times this interface has been discovered.
    public let heardCount: Int?
    /// Distance in hops from discovery source.
    public let hops: Int?
    /// Proof-of-work stamp value.
    public let stampValue: Int?
    /// Host/IP for TCP interfaces or b32 address for I2P.
    public let reachableOn: String?
    /// TCP port.
    public let port: Int?
    /// Frequency in Hz (RNS may emit a float).
    public let frequency: Double?
    /// Bandwidth in Hz.
    public let bandwidth: Int?
    /// LoRa spreading factor (5-12).
    public let spreadingFactor: Int?
    /// LoRa coding rate (5-8).
    public let codingRate: Int?
    /// Modulation type.
    public let modulation: String?
    /// Channel number (for Weave).
    public let channel: Int?
    /// Latitude (optional, for interfaces that share location).
    public let latitude: Double?
    /// Longitude (optional, for interfaces that share location).
    public let longitude: Double?
    /// Altitude in meters.
    public let height: Double?
    /// IFAC network name (Interface Access Code).
    public let ifacNetname: String?
    /// IFAC passphrase.
    public let ifacNetkey: String?
    /// Whether the remote interface is a transport (routing) node.
    public let transport: Bool
    /// Unique identifier for this announce (hex SHA256 of transportId + name).
    public let discoveryHash: String?
    /// When the remote generated the announce (unix seconds).
    public let receivedAt: Double?
    /// When we first discovered this interface locally (unix seconds).
    public let discoveredAt: Double?

    // MARK: - Identifiable

    /// Stable identity: the discovery hash when present, otherwise a
    /// synthesized `type#name#reachableOn` key.
    public var id: String {
        discoveryHash ?? "\(type)#\(name)#\(reachableOn ?? "")"
    }

    // MARK: - Derived properties (mirror the Kotlin model exactly)

    /// Whether this is a TCP-based interface.
    ///
    /// `BackboneInterface` is the RNS 1.1.x upgraded TCP connection type.
    public var isTcpInterface: Bool {
        type == "TCPServerInterface" || type == "TCPClientInterface" || type == "BackboneInterface"
    }

    /// Whether this is a radio-based interface.
    public var isRadioInterface: Bool {
        type == "RNodeInterface" || type == "WeaveInterface" || type == "KISSInterface"
    }

    /// Whether location information is available.
    public var hasLocation: Bool {
        latitude != nil && longitude != nil
    }

    // MARK: - Init (all defaulted, for app code and tests)

    public init(
        name: String = "Unknown",
        type: String = "Unknown",
        status: String = "unknown",
        transportId: String? = nil,
        networkId: String? = nil,
        statusCode: Int? = nil,
        lastHeard: Double = 0,
        heardCount: Int? = nil,
        hops: Int? = nil,
        stampValue: Int? = nil,
        reachableOn: String? = nil,
        port: Int? = nil,
        frequency: Double? = nil,
        bandwidth: Int? = nil,
        spreadingFactor: Int? = nil,
        codingRate: Int? = nil,
        modulation: String? = nil,
        channel: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        height: Double? = nil,
        ifacNetname: String? = nil,
        ifacNetkey: String? = nil,
        transport: Bool = false,
        discoveryHash: String? = nil,
        receivedAt: Double? = nil,
        discoveredAt: Double? = nil
    ) {
        self.name = name
        self.type = type
        self.status = status
        self.transportId = transportId
        self.networkId = networkId
        self.statusCode = statusCode
        self.lastHeard = lastHeard
        self.heardCount = heardCount
        self.hops = hops
        self.stampValue = stampValue
        self.reachableOn = reachableOn
        self.port = port
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.spreadingFactor = spreadingFactor
        self.codingRate = codingRate
        self.modulation = modulation
        self.channel = channel
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
        self.ifacNetname = ifacNetname
        self.ifacNetkey = ifacNetkey
        self.transport = transport
        self.discoveryHash = discoveryHash
        self.receivedAt = receivedAt
        self.discoveredAt = discoveredAt
    }

    // MARK: - Lenient decoding

    /// Lenient decoder (mirrors the Android `parseItem` semantics):
    /// - every key is optional — absent keys fall back to defaults or `nil`
    ///   (never throws on missing keys);
    /// - integral fields are decoded as JSON numbers (RNS may emit floats
    ///   like `4242.0`), rounded to `Int?`;
    /// - empty strings decode as `nil` for the optional string fields
    ///   (Kotlin `optString(...).ifEmpty { null }`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unknown"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Unknown"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        transportId = Self.emptyStringToNil(try c.decodeIfPresent(String.self, forKey: .transportId))
        networkId = Self.emptyStringToNil(try c.decodeIfPresent(String.self, forKey: .networkId))
        statusCode = try Self.decodeInt(c, forKey: .statusCode)
        lastHeard = try c.decodeIfPresent(Double.self, forKey: .lastHeard) ?? 0
        heardCount = try Self.decodeInt(c, forKey: .heardCount)
        hops = try Self.decodeInt(c, forKey: .hops)
        stampValue = try Self.decodeInt(c, forKey: .stampValue)
        reachableOn = Self.emptyStringToNil(try c.decodeIfPresent(String.self, forKey: .reachableOn))
        port = try Self.decodeInt(c, forKey: .port)
        frequency = try c.decodeIfPresent(Double.self, forKey: .frequency)
        bandwidth = try Self.decodeInt(c, forKey: .bandwidth)
        spreadingFactor = try Self.decodeInt(c, forKey: .spreadingFactor)
        codingRate = try Self.decodeInt(c, forKey: .codingRate)
        modulation = Self.emptyStringToNil(try c.decodeIfPresent(String.self, forKey: .modulation))
        channel = try Self.decodeInt(c, forKey: .channel)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        height = try c.decodeIfPresent(Double.self, forKey: .height)
        ifacNetname = Self.emptyStringToNil(try c.decodeIfPresent(String.self, forKey: .ifacNetname))
        ifacNetkey = Self.emptyStringToNil(try c.decodeIfPresent(String.self, forKey: .ifacNetkey))
        transport = try c.decodeIfPresent(Bool.self, forKey: .transport) ?? false
        discoveryHash = Self.emptyStringToNil(try c.decodeIfPresent(String.self, forKey: .discoveryHash))
        receivedAt = try c.decodeIfPresent(Double.self, forKey: .receivedAt)
        discoveredAt = try c.decodeIfPresent(Double.self, forKey: .discoveredAt)
    }

    // MARK: - Decode helpers

    /// RNS may emit integral values as JSON floats (`"port": 4242.0`).
    /// Decode as `Double?` and round; absent or null keys stay `nil`.
    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Int? {
        try c.decodeIfPresent(Double.self, forKey: key).map { Int($0.rounded()) }
    }

    /// Empty string -> `nil` (Kotlin `optString(...).ifEmpty { null }`).
    private static func emptyStringToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case status
        case transportId = "transport_id"
        case networkId = "network_id"
        case statusCode = "status_code"
        case lastHeard = "last_heard"
        case heardCount = "heard_count"
        case hops
        case stampValue = "stamp_value"
        case reachableOn = "reachable_on"
        case port
        case frequency
        case bandwidth
        case spreadingFactor = "spreading_factor"
        case codingRate = "coding_rate"
        case modulation
        case channel
        case latitude
        case longitude
        case height
        case ifacNetname = "ifac_netname"
        case ifacNetkey = "ifac_netkey"
        case transport
        case discoveryHash = "discovery_hash"
        case receivedAt = "received"
        case discoveredAt = "discovered"
    }
}

/// Top-level shape of `rns_bridge.discovery_json()` (a later task).
public struct DiscoverySnapshot: Codable, Equatable, Sendable {
    /// Interfaces seen most recently first (quality-ordered by the backend).
    public let discovered: [DiscoveredInterface]
    /// Whether discovery is currently enabled.
    public let enabled: Bool
    /// Node IDs the app autoconnected to.
    public let autoconnected: [String]

    public init(
        discovered: [DiscoveredInterface] = [],
        enabled: Bool = false,
        autoconnected: [String] = []
    ) {
        self.discovered = discovered
        self.enabled = enabled
        self.autoconnected = autoconnected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        discovered = try c.decodeIfPresent([DiscoveredInterface].self, forKey: .discovered) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        autoconnected = try c.decodeIfPresent([String].self, forKey: .autoconnected) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case discovered
        case enabled
        case autoconnected
    }
}
