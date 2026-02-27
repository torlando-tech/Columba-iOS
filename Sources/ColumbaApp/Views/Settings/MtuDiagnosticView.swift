//
//  MtuDiagnosticView.swift
//  ColumbaApp
//
//  On-device integration test for Link MTU Discovery.
//  Tests AutoInterface peer discovery and MTU negotiation
//  with a real remote peer (e.g., Android Columba).
//

import SwiftUI
import ReticulumSwift
import os.log

private let diagLogger = Logger(subsystem: "com.columba.app", category: "MtuDiag")

@available(iOS 17.0, macOS 14.0, *)
struct MtuDiagnosticView: View {
    let appServices: AppServices

    @State private var runner = MtuDiagRunner()
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                statusSection
                logSection
            }
            .padding(16)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle("MTU Diagnostic")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tests Link MTU Discovery with a remote peer via AutoInterface (LAN multicast).")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 12) {
                Button(action: {
                    guard !isRunning else { return }
                    isRunning = true
                    Task {
                        await runner.run(appServices: appServices)
                        isRunning = false
                    }
                }) {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                        }
                        Text(isRunning ? "Running..." : "Run Test")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(isRunning ? Theme.accentColor.opacity(0.6) : Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isRunning)

                if !runner.log.isEmpty {
                    Button("Clear") {
                        runner.reset()
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(isRunning)
                }
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !runner.results.isEmpty {
                ForEach(runner.results) { result in
                    HStack(spacing: 8) {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.passed ? Theme.success : Theme.error)
                            .font(.system(size: 14))
                        Text(result.label)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !runner.log.isEmpty {
                Text("Log")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)

                Text(runner.log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Test Result

struct MtuDiagResult: Identifiable {
    let id = UUID()
    let label: String
    let passed: Bool
}

// MARK: - Test Runner

@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
class MtuDiagRunner {
    var log: String = ""
    var results: [MtuDiagResult] = []

    func reset() {
        log = ""
        results = []
    }

    private func emit(_ msg: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(fmt.string(from: Date()))] \(msg)\n"
        log += line
        diagLogger.info("\(msg, privacy: .public)")
    }

    private func result(_ label: String, passed: Bool) {
        results.append(MtuDiagResult(label: label, passed: passed))
        emit("\(passed ? "PASS" : "FAIL"): \(label)")
    }

    func run(appServices: AppServices) async {
        reset()
        emit("MTU Diagnostic starting...")

        // PART 1: Check existing app transport (if AutoInterface is running)
        await testExistingTransport(appServices: appServices)

        // PART 2: Standalone AutoInterface test
        await testStandaloneAutoInterface()

        emit("")
        let allPassed = results.allSatisfy { $0.passed }
        emit(allPassed ? "ALL TESTS PASSED" : "SOME TESTS FAILED")
    }

    // MARK: - Part 1: Use existing app transport

    private func testExistingTransport(appServices: AppServices) async {
        emit("")
        emit("=== PART 1: Existing transport interface check ===")

        guard let transport = appServices.transport else {
            emit("No transport available (app not connected)")
            result("Transport available", passed: false)
            return
        }
        result("Transport available", passed: true)

        let interfaceIds = await transport.listInterfaceIds()
        emit("Registered interfaces: \(interfaceIds)")

        let hasAuto = interfaceIds.contains(where: { $0.hasPrefix("auto") })
        result("AutoInterface registered", passed: hasAuto)

        if !hasAuto {
            emit("No AutoInterface peers. Enable AutoInterface in settings first.")
            return
        }

        // Check if any paths point to auto interfaces
        guard let pathTable = appServices.pathTable else {
            emit("No path table")
            return
        }

        let paths = await pathTable.allEntries()
        emit("Path table has \(paths.count) entries")

        var autoPathCount = 0
        for path in paths {
            if path.interfaceId.hasPrefix("auto") {
                autoPathCount += 1
                let destHex = path.destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                let hwMtu = await transport.nextHopInterfaceHwMtu(for: path.destinationHash)
                emit("  dest=\(destHex)... iface=\(path.interfaceId) hwMtu=\(String(describing: hwMtu))")

                if let hwMtu = hwMtu {
                    result("hwMtu for \(destHex)...=\(hwMtu)", passed: hwMtu == 1196)
                } else {
                    result("hwMtu lookup for \(destHex)...", passed: false)
                }
            }
        }

        if autoPathCount == 0 {
            emit("No paths via AutoInterface peers yet (no announces received from LAN peers)")
        }

        result("Auto paths found: \(autoPathCount)", passed: autoPathCount > 0)
    }

    // MARK: - Part 2: Standalone AutoInterface

    private func testStandaloneAutoInterface() async {
        emit("")
        emit("=== PART 2: Standalone AutoInterface MTU test ===")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtu_diag_\(ProcessInfo.processInfo.processIdentifier)")

        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let pathTable = try PathTable(
                databasePath: tmpDir.appendingPathComponent("paths.db").path
            )
            let transport = ReticuLumTransport(pathTable: pathTable)
            let identity = Identity()

            // Create AutoInterface
            let config = InterfaceConfig(
                id: "diag-auto",
                name: "Diag Auto",
                type: .autoInterface,
                enabled: true,
                mode: .full,
                host: "reticulum",
                port: 0
            )
            let autoIface = AutoInterface(config: config)
            try await transport.addAutoInterface(autoIface)
            result("AutoInterface created", passed: true)

            // Verify hwMtu
            let hwMtu = await autoIface.hwMtu
            emit("AutoInterface.hwMtu = \(hwMtu)")
            result("AutoInterface.hwMtu == 1196", passed: hwMtu == 1196)

            // Wait for connection
            emit("Waiting for AutoInterface to connect...")
            var connected = false
            for _ in 0..<10 {
                if await autoIface.state == .connected {
                    connected = true
                    break
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            result("AutoInterface connected", passed: connected)
            if !connected {
                emit("AutoInterface did not connect (no suitable network interface?)")
                return
            }

            // Wait for peer discovery + announce
            emit("Waiting for LAN peer discovery and announces (up to 60s)...")
            var pathEntry: PathEntry?
            var autoPathInterfaceId: String?

            for i in 0..<120 {
                let paths = await pathTable.allEntries()
                for path in paths {
                    if path.interfaceId.hasPrefix("auto") {
                        pathEntry = path
                        autoPathInterfaceId = path.interfaceId
                        break
                    }
                }
                if pathEntry != nil { break }
                if i > 0 && i % 20 == 0 {
                    emit("  Still waiting for announce... (\(i / 2)s)")
                    // Re-check registered interfaces
                    let ids = await transport.listInterfaceIds()
                    let autoIds = ids.filter { $0.hasPrefix("auto") }
                    emit("  Registered auto interfaces: \(autoIds)")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            guard let pathEntry = pathEntry, let autoIfaceId = autoPathInterfaceId else {
                result("Received announce via AutoInterface", passed: false)
                emit("No announce received from any LAN peer in 60s")
                return
            }

            let destHex = pathEntry.destinationHash.map { String(format: "%02x", $0) }.joined()
            emit("Got path: dest=\(destHex), iface=\(autoIfaceId)")
            result("Received announce via AutoInterface", passed: true)

            // Check hwMtu via transport
            let resolvedHwMtu = await transport.nextHopInterfaceHwMtu(for: pathEntry.destinationHash)
            emit("nextHopInterfaceHwMtu = \(String(describing: resolvedHwMtu))")
            result("nextHopInterfaceHwMtu == 1196", passed: resolvedHwMtu == 1196)

            // Try to initiate a link
            emit("Attempting link to dest \(destHex.prefix(16))...")
            do {
                let remoteIdentity = try Identity(publicKeyBytes: pathEntry.publicKeys)
                // We don't know the remote app_name/aspects, so construct a destination
                // that matches the hash directly. We use the path entry's stored hash.
                // NOTE: For a real link, the remote side must have a matching destination.
                // We'll try and if it fails, we at least verified the MTU path above.

                // Try common Columba destinations
                let appNames = ["lxmf", "automtutest"]
                let aspectsList = [["delivery"], ["echo"]]

                var linkEstablished = false
                for (appName, aspects) in zip(appNames, aspectsList) {
                    let remoteDest = Destination(
                        identity: remoteIdentity,
                        appName: appName,
                        aspects: aspects,
                        type: .single,
                        direction: .out
                    )

                    // Check if hash matches
                    if remoteDest.hash == pathEntry.destinationHash {
                        emit("Destination hash matches for \(appName).\(aspects.joined(separator: "."))")

                        let link = try await transport.initiateLink(to: remoteDest, identity: identity)
                        emit("Link initiated, waiting for PROOF...")

                        var active = false
                        for _ in 0..<60 {
                            let state = await link.state
                            if state == .active {
                                active = true
                                break
                            }
                            if case .closed = state { break }
                            try await Task.sleep(nanoseconds: 500_000_000)
                        }

                        if active {
                            let linkMtu = await link.mtu
                            let linkMdu = await link.mdu
                            emit("Link ACTIVE! mtu=\(linkMtu), mdu=\(linkMdu)")
                            result("Link MTU negotiated > 500", passed: linkMtu > 500)
                            result("Link MTU = \(linkMtu)", passed: true)
                            linkEstablished = true
                        } else {
                            emit("Link did not become active (state: \(await link.state))")
                        }
                        break
                    }
                }

                if !linkEstablished {
                    emit("Could not match destination hash to known app names")
                    emit("(hwMtu verification still valid - link test skipped)")
                    result("Link test", passed: false)
                }
            } catch {
                emit("Link attempt error: \(error)")
                result("Link attempt", passed: false)
            }

            // Cleanup
            await autoIface.disconnect()

        } catch {
            emit("Error: \(error)")
            result("Test setup", passed: false)
        }
    }
}
