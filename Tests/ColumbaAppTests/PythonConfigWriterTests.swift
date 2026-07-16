//
//  PythonConfigWriterTests.swift
//  ColumbaAppTests
//
//  Regression coverage for the RNS config text emitted by PythonConfigWriter.
//  Guards the crash-on-launch bug where RNode/Multipeer placeholder interfaces
//  emitted `enabled` twice in one section (`enabled = yes` from the shared
//  header + `enabled = no` from the per-type block) — RNS's configobj rejects a
//  duplicate keyword with a DuplicateError, so the Python backend failed to
//  start and the app terminated on launch.
//

import XCTest
import RNSAPI
@testable import ColumbaApp

final class PythonConfigWriterTests: XCTestCase {

    /// Count `enabled = …` lines (excluding `interface_enabled`) inside the
    /// single interface section of a one-interface config.
    private func enabledLines(_ config: String) -> [String] {
        config
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("enabled =") }
    }

    func testRNodePlaceholderEmitsEnabledExactlyOnceAndDisabled() {
        let iface = InterfaceEntity(
            name: "RNode Radio",
            type: .rnode,
            config: .rnode(RNodeConfig())
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        let enabled = enabledLines(config)
        XCTAssertEqual(enabled, ["enabled = no"],
                       "RNode placeholder must emit `enabled` exactly once, disabled — got \(enabled)\n\(config)")
    }

    func testMultipeerPlaceholderEmitsEnabledExactlyOnceAndDisabled() {
        let iface = InterfaceEntity(
            name: "Multipeer",
            type: .multipeer,
            config: .multipeer(MultipeerConfig())
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        XCTAssertEqual(enabledLines(config), ["enabled = no"],
                       "Multipeer placeholder must emit `enabled` exactly once, disabled\n\(config)")
    }

    func testRealInterfaceEmitsEnabledExactlyOnceAndEnabled() {
        let iface = InterfaceEntity(
            name: "kin",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(targetHost: "rns.kin.earth", targetPort: 4242))
        )
        let config = PythonConfigWriter.write(interfaces: [iface])

        XCTAssertEqual(enabledLines(config), ["enabled = yes"],
                       "A real interface must emit `enabled = yes` exactly once\n\(config)")
    }
}
