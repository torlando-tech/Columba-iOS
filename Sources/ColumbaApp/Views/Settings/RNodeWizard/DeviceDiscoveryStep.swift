//
//  DeviceDiscoveryStep.swift
//  ColumbaApp
//
//  RNode Wizard Step 1: BLE device discovery and selection.
//  Scans for RNode devices via CoreBluetooth and displays them with RSSI.
//

#if canImport(CoreBluetooth)
import SwiftUI
import CoreBluetooth
import ReticulumSwift

/// Step 1: Scan for and select an RNode BLE device.
@available(iOS 17.0, macOS 14.0, *)
struct DeviceDiscoveryStep: View {

    @Bindable var wizard: RNodeWizardViewModel

    @State private var isScanning = false
    @State private var discoveredDevices: [DiscoveredDevice] = []
    @State private var lastUpdateTime: [UUID: Date] = [:]
    @State private var scanTransport: BLETransport?

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

                Text("Make sure your RNode is powered on and in range.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
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
        }
    }

    // MARK: - Device Card

    private func deviceCard(_ device: DiscoveredDevice) -> some View {
        Button {
            selectDevice(device)
        } label: {
            HStack(spacing: 12) {
                // Radio icon
                Image(systemName: "radio")
                    .font(.title2)
                    .foregroundStyle(isSelected(device) ? Theme.accentColor : Theme.textSecondary)
                    .frame(width: 40)

                // Device info
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)

                    Text("Bluetooth LE")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                // RSSI indicator
                rssiIndicator(rssi: device.rssi)

                // Selection checkmark
                if isSelected(device) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .padding(14)
            .background(isSelected(device) ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                    .stroke(isSelected(device) ? Theme.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
    }

    private func isSelected(_ device: DiscoveredDevice) -> Bool {
        wizard.selectedDeviceName == device.name
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
        let transport = BLETransport(deviceName: nil)
        transport.onPeripheralDiscovered = { peripheral, rssi in
            handleDiscovery(peripheral: peripheral, rssi: rssi)
        }
        scanTransport = transport
        isScanning = true
        transport.connect()
    }

    private func stopScanning() {
        scanTransport?.disconnect()
        scanTransport = nil
        isScanning = false
    }

    private func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    private func handleDiscovery(peripheral: CBPeripheral, rssi: NSNumber) {
        guard let name = peripheral.name, !name.isEmpty else { return }

        let peripheralId = peripheral.identifier
        let rssiInt = rssi.intValue
        let now = Date()

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
        discoveredDevices.sort { $0.rssi > $1.rssi }
    }

    private func selectDevice(_ device: DiscoveredDevice) {
        wizard.selectedDeviceName = device.name
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
