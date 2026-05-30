#if COLUMBA_RNODE_ENABLED
//
//  DeviceDiscoveryStep.swift
//  ColumbaApp
//
//  RNode Wizard Step 1: BLE device discovery and selection.
//  Scans for RNode devices via CoreBluetooth and displays them with RSSI.
//

#if canImport(CoreBluetooth)
import SwiftUI
import RNSAPI
import CoreBluetooth

/// Step 1: Scan for and select an RNode BLE device.
@available(iOS 17.0, macOS 14.0, *)
struct DeviceDiscoveryStep: View {

    @Bindable var wizard: RNodeWizardViewModel

    @State private var isScanning = false
    @State private var discoveredDevices: [DiscoveredDevice] = []
    @State private var lastUpdateTime: [UUID: Date] = [:]

    /// Peripheral references keyed by peripheral UUID.
    @State private var peripheralRefs: [UUID: CBPeripheral] = [:]

    // Verification state
    @State private var pairingDeviceName: String?
    @State private var pairingError: String?
    @State private var detectTimeoutTask: Task<Void, Never>?

    /// Lightweight BLE scanner — no restore identifier, no auto-reconnect.
    @State private var scanner: RNodeProbeScanner?

    /// Debug log lines shown in UI for diagnosing probe issues.
    @State private var debugLog: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accentColor)
                    .padding(.top, 24)

                Text("Find Your RNode")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text("Make sure your RNode is powered on and in **pairing mode**.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text("Hold the USR button for 5 seconds to enter pairing mode.")
                    .font(.caption)
                    .foregroundStyle(Theme.accentColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 16)

            // Scan button
            Button {
                toggleScanning()
            } label: {
                HStack(spacing: 8) {
                    if isScanning {
                        ProgressView()
                            .tint(Theme.accentColor)
                            .scaleEffect(0.8)
                    }
                    Text(isScanning ? "Scanning..." : "Scan for Devices")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(isScanning ? Theme.textPrimary : .white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(isScanning ? Theme.backgroundSecondary : Theme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.bottom, 16)

            // Pairing hint — shown while connecting so user knows what to expect
            if pairingDeviceName != nil {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Theme.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When the Bluetooth pairing dialog appears, tap **Pair**.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text("If the RNode isn't responding, hold the left (USR) button for 5 seconds to enter pairing mode.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Pairing error
            if let error = pairingError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.error)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Theme.error.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Debug log (temporary — shows probe events in-app)
            if !debugLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(debugLog.suffix(6), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textDisabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Device list
            if discoveredDevices.isEmpty && !isScanning {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.textDisabled)
                    Text("No devices found")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Tap Scan to search for nearby RNode devices")
                        .font(.caption)
                        .foregroundStyle(Theme.textDisabled)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discoveredDevices) { device in
                            deviceCard(device)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .onAppear {
            // Auto-start scanning if no device selected
            if wizard.selectedDeviceName.isEmpty {
                startScanning()
            }
        }
        .onDisappear {
            stopScanning()
            detectTimeoutTask?.cancel()
            detectTimeoutTask = nil
        }
    }

    // MARK: - Device Card

    private func deviceCard(_ device: DiscoveredDevice) -> some View {
        let isPairing = pairingDeviceName == device.name
        let isPaired = wizard.selectedDeviceName == device.name && wizard.devicePaired

        return Button {
            selectDevice(device)
        } label: {
            HStack(spacing: 12) {
                // Radio icon
                Image(systemName: "radio")
                    .font(.title2)
                    .foregroundStyle(isPaired ? Theme.accentColor : Theme.textSecondary)
                    .frame(width: 40)

                // Device info
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    if isPairing {
                        Text("Connecting...")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if isPaired {
                        Text("Ready")
                            .font(.caption)
                            .foregroundStyle(Theme.success)
                    } else {
                        Text("Bluetooth LE")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()

                if isPairing {
                    ProgressView()
                        .tint(.orange)
                        .scaleEffect(0.8)
                } else {
                    // RSSI indicator
                    rssiIndicator(rssi: device.rssi)
                }

                // Selection checkmark
                if isPaired {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(14)
            .background(isPaired ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                    .stroke(isPaired ? Theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .disabled(isPairing)
    }

    // MARK: - RSSI Indicator

    private func rssiIndicator(rssi: Int) -> some View {
        HStack(spacing: 2) {
            Rectangle()
                .fill(signalColor(rssi: rssi, threshold: 200))
                .frame(width: 5, height: 7)
                .clipShape(RoundedRectangle(cornerRadius: 1))

            Rectangle()
                .fill(signalColor(rssi: rssi, threshold: 80))
                .frame(width: 5, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 1))

            Rectangle()
                .fill(signalColor(rssi: rssi, threshold: 60))
                .frame(width: 5, height: 17)
                .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }

    private func signalColor(rssi: Int, threshold: Int) -> Color {
        let absRssi = abs(rssi)
        if absRssi < threshold {
            if absRssi < 60 { return Theme.success }
            else if absRssi < 80 { return .orange }
            else { return Theme.error }
        }
        return Color.gray.opacity(0.3)
    }

    // MARK: - Scan Control

    private func startScanning() {
        // Reuse existing scanner if available
        if let existing = scanner {
            existing.startScan()
            isScanning = true
            return
        }

        let probe = RNodeProbeScanner()
        probe.onDiscovered = { peripheral, rssi in
            handleDiscovery(peripheral: peripheral, rssi: rssi)
        }
        probe.onProbeResult = { result in
            addDebug("probe: \(result)")
            handleProbeResult(result)
        }
        scanner = probe
        isScanning = true
        addDebug("scanner created, starting scan")
        probe.startScan()
    }

    private func stopScanning() {
        scanner?.shutdown()
        scanner = nil
        isScanning = false
    }

    private func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    private func handleDiscovery(peripheral: CBPeripheral, rssi: NSNumber) {
        guard let name = peripheral.name, !name.isEmpty else { return }
        // Only show RNode devices
        guard name.hasPrefix("RNode") else { return }

        let peripheralId = peripheral.identifier
        let rssiInt = rssi.intValue
        let now = Date()

        // Store peripheral reference for later probe
        peripheralRefs[peripheralId] = peripheral

        if let index = discoveredDevices.firstIndex(where: { $0.peripheralId == peripheralId }) {
            if let lastUpdate = lastUpdateTime[peripheralId],
               now.timeIntervalSince(lastUpdate) < 1.0 { return }
            if abs(rssiInt - discoveredDevices[index].rssi) < 5 { return }
            discoveredDevices[index].rssi = rssiInt
            discoveredDevices[index].lastSeen = now
            lastUpdateTime[peripheralId] = now
        } else {
            discoveredDevices.append(DiscoveredDevice(
                peripheralId: peripheralId,
                name: name,
                rssi: rssiInt,
                lastSeen: now
            ))
            lastUpdateTime[peripheralId] = now
        }
        // Stable ordering by name (tie-break on peripheral id), NOT by RSSI.
        // Sorting by RSSI made rows jump every signal update — with two RNodes
        // nearby at similar strength they alternated positions, so you couldn't
        // reliably tap one. Name order is deterministic and never reorders as
        // signal fluctuates; the per-row RSSI bars still update live.
        discoveredDevices.sort {
            $0.name == $1.name
                ? $0.peripheralId.uuidString < $1.peripheralId.uuidString
                : $0.name < $1.name
        }
    }

    // MARK: - Debug

    private func addDebug(_ msg: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        debugLog.append("[\(ts)] \(msg)")
        if debugLog.count > 20 { debugLog.removeFirst() }
    }

    // MARK: - Device Selection & Probe

    private func selectDevice(_ device: DiscoveredDevice) {
        // If already verified, do nothing
        if wizard.selectedDeviceName == device.name && wizard.devicePaired { return }

        // Cancel any in-progress verification
        detectTimeoutTask?.cancel()
        detectTimeoutTask = nil

        wizard.selectedDeviceName = device.name
        wizard.devicePaired = false
        pairingError = nil
        pairingDeviceName = device.name

        // Look up the CBPeripheral reference from the scan
        guard let peripheral = peripheralRefs[device.peripheralId],
              let probe = scanner else {
            let hasRef = peripheralRefs[device.peripheralId] != nil
            let hasScanner = scanner != nil
            addDebug("select failed: ref=\(hasRef) scanner=\(hasScanner)")
            pairingError = "Device no longer available. Try scanning again."
            pairingDeviceName = nil
            return
        }

        // Start probe with 8-second timeout
        addDebug("probing \(device.name) id=\(device.peripheralId.uuidString.prefix(8))")
        probe.probe(peripheral)

        detectTimeoutTask = Task { @MainActor in
            // 20s to allow for: connect + reads + notify retry (3s) + reconnect + detect
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            if !wizard.devicePaired && pairingDeviceName != nil {
                pairingDeviceName = nil
                pairingError = "RNode not responding. Make sure it is powered on."
                probe.cancelProbe()
            }
        }
    }

    private func handleProbeResult(_ result: RNodeProbeScanner.ProbeResult) {
        switch result {
        case .connecting, .connected, .servicesFound, .characteristicsReady, .detectSent, .detectWriteConfirmed:
            break // Progress — waiting for detect response

        case .detectResponseReceived:
            // RNode firmware responded — device is verified!
            detectTimeoutTask?.cancel()
            detectTimeoutTask = nil
            pairingDeviceName = nil
            wizard.devicePaired = true
            // Resume scanning for potential re-selection
            scanner?.cancelProbe()

        case .detectWriteFailed(let error):
            detectTimeoutTask?.cancel()
            detectTimeoutTask = nil
            pairingDeviceName = nil
            pairingError = "Write failed: \(error)"
            wizard.devicePaired = false
            scanner?.cancelProbe()

        case .failed(let message):
            if message.contains("Pairing required") {
                // iOS is showing the BLE pairing dialog. Keep "Connecting..." visible.
                // Cancel the original 8s timeout — the full pairing + bond + detect
                // flow takes longer. Give 30s for the user to interact.
                detectTimeoutTask?.cancel()
                let probe = scanner
                detectTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled else { return }
                    if !wizard.devicePaired && pairingDeviceName != nil {
                        pairingDeviceName = nil
                        pairingError = "Pairing timed out. Please try again."
                        wizard.devicePaired = false
                        probe?.cancelProbe()
                    }
                }
                // Stay connected — do NOT call cancelProbe() here. Disconnecting while
                // iOS is negotiating the bond causes it to re-show the pairing dialog
                // on the next connect, creating the loop. RNodeProbeScanner will auto-
                // reconnect via didDisconnectPeripheral if iOS drops us after bonding,
                // and will retry TX notify after 2s if iOS upgrades in-place.
                return
            }
            detectTimeoutTask?.cancel()
            detectTimeoutTask = nil
            pairingDeviceName = nil
            pairingError = message
            wizard.devicePaired = false
            // Resume scanning
            scanner?.cancelProbe()
        }
    }
}

#else

// MARK: - macOS Stub

@available(iOS 17.0, macOS 14.0, *)
struct DeviceDiscoveryStep: View {
    @Bindable var wizard: RNodeWizardViewModel

    var body: some View {
        VStack {
            Text("BLE not available on this platform")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
#endif
