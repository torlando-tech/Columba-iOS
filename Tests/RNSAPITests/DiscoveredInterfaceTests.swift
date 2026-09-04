import XCTest
@testable import RNSAPI

/// Tests for the DiscoveredInterface model (lenient decode), DiscoverySnapshot,
/// and the discovery display formatters (type filter/classification, Yggdrasil
/// detection, interface type display, relative last-heard, haversine, LoRa
/// clipboard block, sorting, filtering) — the Swift port of the Android
/// DiscoveredInterface.kt + DiscoveredInterfacesScreen display helpers.
///
/// Lives in the RNSAPI SwiftPM test target (pure Foundation) so it runs
/// natively via `swift test`.
final class DiscoveredInterfaceTests: XCTestCase {

    // MARK: - Fixtures

    private let fullJSON = """
    {
      "name": "alpha",
      "type": "RNodeInterface",
      "transport_id": "t1",
      "network_id": "n1",
      "status": "available",
      "status_code": 1000.0,
      "last_heard": 1700000000.5,
      "heard_count": 7.0,
      "hops": 1.0,
      "stamp_value": 30.0,
      "reachable_on": "2001:db8::1",
      "port": 4242.0,
      "frequency": 434000000.0,
      "bandwidth": 125000.0,
      "spreading_factor": 9.0,
      "coding_rate": 7.0,
      "modulation": "GFSK",
      "channel": 1.0,
      "latitude": 51.5,
      "longitude": -0.12,
      "height": 42.5,
      "ifac_netname": "columba",
      "ifac_netkey": "secret",
      "transport": true,
      "discovery_hash": "abc123",
      "received": 1699999900.0,
      "discovered": 1699999901.0
    }
    """

    private func decode(_ json: String) throws -> DiscoveredInterface {
        try JSONDecoder().decode(DiscoveredInterface.self, from: json.data(using: .utf8)!)
    }

    private func iface(
        name: String = "n",
        type: String = "Unknown",
        reachableOn: String? = nil,
        ifacNetname: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> DiscoveredInterface {
        DiscoveredInterface(
            name: name,
            type: type,
            reachableOn: reachableOn,
            ifacNetname: ifacNetname,
            latitude: latitude,
            longitude: longitude
        )
    }

    // MARK: - Decode

    func testFullJSONDecode() throws {
        let iface = try decode(fullJSON)
        XCTAssertEqual(iface.name, "alpha")
        XCTAssertEqual(iface.type, "RNodeInterface")
        XCTAssertEqual(iface.transportId, "t1")
        XCTAssertEqual(iface.networkId, "n1")
        XCTAssertEqual(iface.status, "available")
        XCTAssertEqual(iface.statusCode, 1000)
        XCTAssertEqual(iface.lastHeard, 1700000000.5)
        XCTAssertEqual(iface.heardCount, 7)
        XCTAssertEqual(iface.hops, 1)
        XCTAssertEqual(iface.stampValue, 30)
        XCTAssertEqual(iface.reachableOn, "2001:db8::1")
        XCTAssertEqual(iface.port, 4242)
        XCTAssertEqual(iface.frequency, 434_000_000.0)
        XCTAssertEqual(iface.bandwidth, 125_000)
        XCTAssertEqual(iface.spreadingFactor, 9)
        XCTAssertEqual(iface.codingRate, 7)
        XCTAssertEqual(iface.modulation, "GFSK")
        XCTAssertEqual(iface.channel, 1)
        XCTAssertEqual(iface.latitude, 51.5)
        XCTAssertEqual(iface.longitude, -0.12)
        XCTAssertEqual(iface.height, 42.5)
        XCTAssertEqual(iface.ifacNetname, "columba")
        XCTAssertEqual(iface.ifacNetkey, "secret")
        XCTAssertTrue(iface.transport)
        XCTAssertEqual(iface.discoveryHash, "abc123")
        XCTAssertEqual(iface.receivedAt, 1699999900.0)
        XCTAssertEqual(iface.discoveredAt, 1699999901.0)
        XCTAssertEqual(iface.id, "abc123")
        XCTAssertTrue(iface.hasLocation)
        XCTAssertTrue(iface.isRadioInterface)
    }

    func testMinimalJSONDecodeDefaults() throws {
        let iface = try decode(#"{"name":"x","type":"RNodeInterface"}"#)
        XCTAssertEqual(iface.name, "x")
        XCTAssertEqual(iface.type, "RNodeInterface")
        XCTAssertEqual(iface.status, "unknown")
        XCTAssertNil(iface.statusCode)
        XCTAssertEqual(iface.lastHeard, 0)
        XCTAssertNil(iface.heardCount)
        XCTAssertNil(iface.hops)
        XCTAssertNil(iface.stampValue)
        XCTAssertNil(iface.port)
        XCTAssertNil(iface.frequency)
        XCTAssertNil(iface.reachableOn)
        XCTAssertNil(iface.discoveryHash)
        XCTAssertNil(iface.receivedAt)
        XCTAssertNil(iface.discoveredAt)
        XCTAssertFalse(iface.transport)
        XCTAssertTrue(iface.isRadioInterface)
        // No discovery hash -> synthesized id from type/name/reachableOn.
        XCTAssertEqual(iface.id, "RNodeInterface#x#")
    }

    func testFloatPortDecodesToInt() throws {
        let iface = try decode(#"{"port": 4242.0}"#)
        XCTAssertEqual(iface.port, 4242)
    }

    func testEmptyStringAndAbsentFields() throws {
        let emptyHost = try decode(#"{"reachable_on": ""}"#)
        XCTAssertNil(emptyHost.reachableOn)
        let empty = try decode("{}")
        XCTAssertEqual(empty.name, "Unknown")
        XCTAssertEqual(empty.type, "Unknown")
        XCTAssertEqual(empty.status, "unknown")
    }

    func testDiscoverySnapshotDecode() throws {
        let json = #"{"discovered":[{"name":"a","type":"TCPServerInterface"},{"name":"b","type":"RNodeInterface"}],"enabled":true,"autoconnected":["node-1","node-2"]}"#
        let snapshot = try JSONDecoder().decode(DiscoverySnapshot.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(snapshot.discovered.count, 2)
        XCTAssertEqual(snapshot.discovered[0].name, "a")
        XCTAssertEqual(snapshot.discovered[1].name, "b")
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.autoconnected, ["node-1", "node-2"])

        let empty = try JSONDecoder().decode(DiscoverySnapshot.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(empty.discovered.isEmpty)
        XCTAssertFalse(empty.enabled)
        XCTAssertTrue(empty.autoconnected.isEmpty)
    }

    // MARK: - Derived properties

    func testIsTcpInterface() {
        XCTAssertTrue(iface(type: "TCPServerInterface").isTcpInterface)
        XCTAssertTrue(iface(type: "TCPClientInterface").isTcpInterface)
        XCTAssertTrue(iface(type: "BackboneInterface").isTcpInterface)
        XCTAssertFalse(iface(type: "I2PInterface").isTcpInterface)
        XCTAssertFalse(iface(type: "RNodeInterface").isTcpInterface)
    }

    func testIsRadioInterface() {
        XCTAssertTrue(iface(type: "RNodeInterface").isRadioInterface)
        XCTAssertTrue(iface(type: "WeaveInterface").isRadioInterface)
        XCTAssertTrue(iface(type: "KISSInterface").isRadioInterface)
        XCTAssertFalse(iface(type: "TCPServerInterface").isRadioInterface)
    }

    func testClassifyBuckets() {
        XCTAssertEqual(DiscoveredTypeFilter.classify(iface(type: "TCPServerInterface")), .tcp)
        XCTAssertEqual(DiscoveredTypeFilter.classify(iface(type: "BackboneInterface")), .tcp)
        XCTAssertEqual(DiscoveredTypeFilter.classify(iface(type: "RNodeInterface")), .radio)
        XCTAssertEqual(DiscoveredTypeFilter.classify(iface(type: "WeaveInterface")), .radio)
        XCTAssertEqual(DiscoveredTypeFilter.classify(iface(type: "I2PInterface")), .i2p)
        // Case-insensitive I2P match.
        XCTAssertEqual(DiscoveredTypeFilter.classify(iface(type: "i2pbuiltininterface")), .i2p)
        XCTAssertEqual(DiscoveredTypeFilter.classify(iface(type: "MysteryInterface")), .other)
    }

    // MARK: - Yggdrasil

    func testIsYggdrasilAddress() {
        XCTAssertTrue(isYggdrasilAddress("[02d0::1]"))
        XCTAssertTrue(isYggdrasilAddress("02d0::1"))
        XCTAssertTrue(isYggdrasilAddress("03ff::2"))
        XCTAssertFalse(isYggdrasilAddress("0400::1"))
        XCTAssertFalse(isYggdrasilAddress("192.168.1.5"))
        XCTAssertFalse(isYggdrasilAddress(nil))
        XCTAssertFalse(isYggdrasilAddress("[0100::1]"))
    }

    // MARK: - Display formatters

    func testFormatInterfaceType() {
        XCTAssertEqual(formatInterfaceType("TCPServerInterface"), "TCP Server")
        XCTAssertEqual(formatInterfaceType("TCPClientInterface"), "TCP Client")
        XCTAssertEqual(formatInterfaceType("BackboneInterface"), "Backbone (TCP)")
        XCTAssertEqual(formatInterfaceType("I2PInterface"), "I2P")
        XCTAssertEqual(formatInterfaceType("RNodeInterface"), "RNode (LoRa)")
        XCTAssertEqual(formatInterfaceType("WeaveInterface"), "Weave (LoRa)")
        XCTAssertEqual(formatInterfaceType("KISSInterface"), "KISS")
        XCTAssertEqual(formatInterfaceType("MysteryInterface"), "MysteryInterface")
    }

    func testFormatLastHeard() {
        let now = 1_000_000_000.0
        XCTAssertEqual(formatLastHeard(0, nowSeconds: now), "Never")
        XCTAssertEqual(formatLastHeard(now - 30, nowSeconds: now), "just now")
        XCTAssertEqual(formatLastHeard(now - 120, nowSeconds: now), "2 min ago")
        XCTAssertEqual(formatLastHeard(now - 7200, nowSeconds: now), "2 hours ago")
        XCTAssertEqual(formatLastHeard(now - 172800, nowSeconds: now), "2 days ago")
        let old = formatLastHeard(now - 900000, nowSeconds: now)
        XCTAssertFalse(old.isEmpty)
    }

    func testHaversineDistance() {
        let d = haversineDistanceKm(lat1: 0, lon1: 0, lat2: 1, lon2: 0)
        XCTAssertEqual(d, 111.19, accuracy: 0.5)
    }

    func testFormatLoraParamsFull() {
        let iface = DiscoveredInterface(
            name: "node-a",
            type: "RNodeInterface",
            frequency: 434_000_000.0,
            bandwidth: 125_000,
            spreadingFactor: 9,
            codingRate: 7,
            modulation: "GFSK"
        )
        XCTAssertEqual(
            formatLoraParamsForClipboard(iface),
            "LoRa Parameters from: node-a\n"
            + "---\n"
            + "Frequency: 434.000000 MHz\n"
            + "Bandwidth: 125 kHz\n"
            + "Spreading Factor: SF9\n"
            + "Coding Rate: 4/7\n"
            + "Modulation: GFSK"
        )
    }

    func testFormatLoraParamsPartial() {
        let iface = DiscoveredInterface(
            name: "lores",
            type: "RNodeInterface",
            frequency: 868_000_000.0,
            modulation: "GFSK"
        )
        XCTAssertEqual(
            formatLoraParamsForClipboard(iface),
            "LoRa Parameters from: lores\n"
            + "---\n"
            + "Frequency: 868.000000 MHz\n"
            + "Modulation: GFSK"
        )
    }

    // MARK: - Sorting

    func testSortQualityPreservesOrder() {
        let input = [iface(name: "x"), iface(name: "y"), iface(name: "z")]
        let sorted = DiscoveredSorter.sort(
            input,
            mode: .availabilityAndQuality,
            userLatitude: 0,
            userLongitude: 0
        )
        XCTAssertEqual(sorted.map { $0.name }, ["x", "y", "z"])
    }

    func testSortProximity() {
        // User at (0, 0). B (~55.6 km) is closest; A and D are tied at
        // ~111.2 km and keep input order (stable tiebreak); C has no
        // location and is appended last in input order.
        let input = [
            iface(name: "C", ifacNetname: "c"),
            iface(name: "A", latitude: 1.0, longitude: 0.0),
            iface(name: "D", latitude: 1.0, longitude: 0.0),
            iface(name: "B", latitude: 0.5, longitude: 0.0),
        ]
        let sorted = DiscoveredSorter.sort(
            input,
            mode: .proximity,
            userLatitude: 0,
            userLongitude: 0
        )
        XCTAssertEqual(sorted.map { $0.name }, ["B", "A", "D", "C"])
    }

    func testSortProximityNilUserLocation() {
        // Without a user location, located interfaces keep input order and
        // non-located ones are still appended in input order.
        let input = [
            iface(name: "C"),
            iface(name: "A", latitude: 1.0, longitude: 0.0),
            iface(name: "B", latitude: 0.5, longitude: 0.0),
        ]
        let sorted = DiscoveredSorter.sort(
            input,
            mode: .proximity,
            userLatitude: nil,
            userLongitude: nil
        )
        XCTAssertEqual(sorted.map { $0.name }, ["A", "B", "C"])
    }

    // MARK: - Filtering

    func testFilterIfacOnly() {
        let input = [
            iface(name: "no-ifac"),
            iface(name: "empty-ifac", ifacNetname: ""),
            iface(name: "has-ifac", ifacNetname: "columba"),
        ]
        let filtered = DiscoveredFilter.apply(input, searchQuery: "", typeFilters: [], ifacOnly: true)
        XCTAssertEqual(filtered.map { $0.name }, ["has-ifac"])
    }

    func testFilterType() {
        let input = [
            iface(name: "tcp", type: "TCPServerInterface"),
            iface(name: "radio", type: "RNodeInterface"),
            iface(name: "i2p", type: "I2PInterface"),
            iface(name: "other", type: "MysteryInterface"),
        ]
        let tcp = DiscoveredFilter.apply(input, searchQuery: "", typeFilters: [.tcp], ifacOnly: false)
        XCTAssertEqual(tcp.map { $0.name }, ["tcp"])
        let mixed = DiscoveredFilter.apply(input, searchQuery: "", typeFilters: [.radio, .other], ifacOnly: false)
        XCTAssertEqual(mixed.map { $0.name }, ["radio", "other"])
    }

    func testFilterSearch() {
        let input = [
            iface(name: "alpha", type: "RNodeInterface", reachableOn: "2001:db8::1", ifacNetname: "columba"),
            iface(name: "beta", type: "TCPServerInterface"),
        ]
        func search(_ q: String) -> [String] {
            DiscoveredFilter.apply(input, searchQuery: q, typeFilters: [], ifacOnly: false).map { $0.name }
        }
        XCTAssertEqual(search("ALP"), ["alpha"])
        XCTAssertEqual(search("db8"), ["alpha"])
        XCTAssertEqual(search("rnode"), ["alpha"])
        XCTAssertEqual(search("columba"), ["alpha"])
        XCTAssertEqual(search("beta"), ["beta"])
    }

    func testFilterAndCombination() {
        let input = [
            iface(name: "alpha", type: "RNodeInterface", reachableOn: "2001:db8::1", ifacNetname: "columba"),
            iface(name: "alpha2", type: "TCPServerInterface", ifacNetname: "columba"),
        ]
        // Search AND type: only the RNode "alpha" matches both.
        let both = DiscoveredFilter.apply(input, searchQuery: "alpha", typeFilters: [.radio], ifacOnly: false)
        XCTAssertEqual(both.map { $0.name }, ["alpha"])
        // Search AND ifacOnly: only the row with both.
        let ifac = DiscoveredFilter.apply(input, searchQuery: "alpha", typeFilters: [], ifacOnly: true)
        XCTAssertEqual(ifac.map { $0.name }, ["alpha"])
        // No row satisfies search + incompatible type.
        let none = DiscoveredFilter.apply(input, searchQuery: "zzz", typeFilters: [.radio], ifacOnly: false)
        XCTAssertTrue(none.isEmpty)
    }

    func testFilterEmptyQueryAndEmptyInput() {
        let input = [iface(name: "a"), iface(name: "b")]
        let unfiltered = DiscoveredFilter.apply(input, searchQuery: "   ", typeFilters: [], ifacOnly: false)
        XCTAssertEqual(unfiltered.map { $0.name }, ["a", "b"])
        let empty = DiscoveredFilter.apply([], searchQuery: "x", typeFilters: [.tcp], ifacOnly: true)
        XCTAssertTrue(empty.isEmpty)
    }
}
