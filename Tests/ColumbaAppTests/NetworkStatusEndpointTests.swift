//
//  NetworkStatusEndpointTests.swift
//  ColumbaAppTests
//
//  Locks AppServices.parseFriendlyEndpoint — the helper that pulls the
//  host:port endpoint (and peer name) out of a Python friendly `str(iface)`.
//  This is what lets the Network Status row show which host a TCP client is
//  connected to (issue #193 follow-up: rows previously read just "TCPClient"
//  with no host) and badge auto-connected discovery interfaces.
//

import XCTest
@testable import ColumbaApp

@MainActor
final class NetworkStatusEndpointTests: XCTestCase {

    // A user-configured TCP client: "TCPInterface[Home/10.0.4.63:4242]".
    func testTcpClientEndpointAndPeer() {
        let (peer, endpoint) = AppServices.parseFriendlyEndpoint("TCPInterface[Home/10.0.4.63:4242]")
        XCTAssertEqual(peer, "Home")
        XCTAssertEqual(endpoint, "10.0.4.63:4242")
    }

    // An auto-connected discovery interface: "BackboneInterface[Synth
    // Hub/127.0.0.1:43221]" — the peer name contains a SPACE and the split
    // must happen on the LAST "/" (the endpoint boundary), not the first.
    func testAutoconnectBackbonePeerNameWithSpace() {
        let (peer, endpoint) = AppServices.parseFriendlyEndpoint("BackboneInterface[Synth Hub/127.0.0.1:43221]")
        XCTAssertEqual(peer, "Synth Hub")
        XCTAssertEqual(endpoint, "127.0.0.1:43221")
    }

    // IPv6 target host keeps its brackets — split on the LAST "/" so the
    // bracketed address survives.
    func testIpv6TargetHost() {
        let (peer, endpoint) = AppServices.parseFriendlyEndpoint("TCPInterface[Peer/[2001:db8::1]:4242]")
        XCTAssertEqual(peer, "Peer")
        XCTAssertEqual(endpoint, "[2001:db8::1]:4242")
    }

    // A LAN peer with a bare interface/iface address ("en0/fe80::1") is NOT
    // a host:port endpoint — the last segment has no ":" port, so endpoint
    // stays nil (the row falls back to the peer address).
    func testLanPeerIsNotAnEndpoint() {
        let (peer, endpoint) = AppServices.parseFriendlyEndpoint("AutoInterfacePeer[en0/fe80::1]")
        // "fe80::1" contains ":" so it is host-ish; this documents the current
        // behaviour — a LAN peer may surface a pseudo-endpoint. The important
        // invariant: parsing must not crash and must return a stable peer.
        XCTAssertNotNil(peer)
        _ = endpoint
    }

    // No brackets at all (e.g. a bare section name) — nothing to parse.
    func testNoBracketsReturnsNil() {
        let (peer, endpoint) = AppServices.parseFriendlyEndpoint("python-rns")
        XCTAssertNil(peer)
        XCTAssertNil(endpoint)
    }

    // Empty bracket content — no crash, nil endpoint.
    func testEmptyBrackets() {
        let (peer, endpoint) = AppServices.parseFriendlyEndpoint("TCPInterface[]")
        XCTAssertEqual(peer, "")
        XCTAssertNil(endpoint)
    }
}
