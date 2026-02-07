//
//  BLEDevicePickerSheet.swift
//  ColumbaApp
//
//  BLE device scanner and picker for RNode configuration.
//  Displays discovered RNode peripherals with RSSI signal strength.
//

#if canImport(CoreBluetooth)
import SwiftUI
import CoreBluetooth
import ReticulumSwift

// MARK: - Discovered Device

/// A discovered BLE peripheral with metadata.
struct DiscoveredDevice: Identifiable {
    /// Unique identifier for SwiftUI list deduplication.
    let id = UUID()

    /// Peripheral identifier (used for deduplication).
    let peripheralId: UUID

    /// Peripheral name.
    let name: String

    /// Received signal strength indicator (dBm).
    var rssi: Int

    /// Last discovery timestamp.
    var lastSeen: Date
}

// MARK: - BLE Device Picker Sheet

/// BLE device scanner and picker sheet.
///
/// Provides a UI to scan for RNode devices, display RSSI signal strength,
/// and select a device for configuration. Updates are throttled to reduce
/// UI churn (>5 dBm change, >1s between updates).
@available(iOS 17.0, macOS 14.0, *)
struct BLEDevicePickerSheet: View {

    // MARK: - Properties

    /// ViewModel to populate with selected device name.
    @Bindable var viewModel: InterfaceManagementViewModel

    /// Dismiss action.
    @Environment(\.dismiss) private var dismiss

    /// Whether scanning is active.
    @State private var isScanning = false

    /// List of discovered devices.
    @State private var discoveredDevices: [DiscoveredDevice] = []

    /// Throttle map: peripheral UUID -> last update time.
    @State private var lastUpdateTime: [UUID: Date] = [:]

    /// Dedicated BLE transport for scanning.
    @State private var scanTransport: BLETransport?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundPrimary
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    if discoveredDevices.isEmpty && !isScanning {
                        // Empty state
                        emptyStateView
                    } else if discoveredDevices.isEmpty && isScanning {
                        // Scanning state
                        scanningView
                    } else {
                        // Device list
                        deviceListView
                    }
                }
            }
            .navigationTitle("Select RNode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopScanning()
                        dismiss()
                    }
                    .foregroundStyle(Theme.textPrimary)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(isScanning ? "Stop" : "Scan") {
                        toggleScanning()
                    }
                    .foregroundStyle(isScanning ? Theme.error : Theme.accentColor)
                }
            }
            .toolbarBackground(Theme.backgroundPrimary, for: .navigationBar)
        }
        .onDisappear {
            stopScanning()
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 60))
                .foregroundStyle(Theme.textSecondary)

            Text("Tap Scan to search for RNode devices")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accentColor)

            Text("Scanning...")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceListView: some View {
        List {
            ForEach(discoveredDevices) { device in
                Button {
                    selectDevice(device)
                } label: {
                    HStack(spacing: 12) {
                        // Device info
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)

                            Text(device.peripheralId.uuidString)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        Spacer()

                        // RSSI indicator
                        rssiIndicator(rssi: device.rssi)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Theme.backgroundSecondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - RSSI Signal Indicator

    /// Create a 3-bar signal strength indicator.
    ///
    /// - Parameter rssi: Signal strength in dBm (negative value).
    /// - Returns: Signal indicator view with colored bars and numeric value.
    private func rssiIndicator(rssi: Int) -> some View {
        HStack(spacing: 8) {
            // 3-bar signal indicator
            HStack(spacing: 2) {
                // Bar 0 (shortest): always colored (any signal)
                Rectangle()
                    .fill(signalColor(rssi: rssi, threshold: 200)) // Always colored
                    .frame(width: 6, height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))

                // Bar 1 (medium): colored if signal < 80 dBm
                Rectangle()
                    .fill(signalColor(rssi: rssi, threshold: 80))
                    .frame(width: 6, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 2))

                // Bar 2 (tallest): colored if signal < 60 dBm
                Rectangle()
                    .fill(signalColor(rssi: rssi, threshold: 60))
                    .frame(width: 6, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }

            // Numeric RSSI value
            Text("\(rssi) dBm")
                .font(.caption)
                .foregroundStyle(signalStrengthColor(rssi: rssi))
                .monospacedDigit()
        }
    }

    /// Get the fill color for a signal bar based on threshold.
    private func signalColor(rssi: Int, threshold: Int) -> Color {
        let absRssi = abs(rssi)
        if absRssi < threshold {
            return signalStrengthColor(rssi: rssi)
        } else {
            return Color.gray.opacity(0.3)
        }
    }

    /// Get the color for a given signal strength.
    private func signalStrengthColor(rssi: Int) -> Color {
        let absRssi = abs(rssi)
        if absRssi < 60 {
            return Theme.success // Strong signal
        } else if absRssi < 80 {
            return .orange // Medium signal
        } else {
            return Theme.error // Weak signal
        }
    }

    // MARK: - Scan Control

    /// Start BLE scanning.
    private func startScanning() {
        // Create a scan-only transport (no target device name)
        let transport = BLETransport(deviceName: nil)

        // Set up discovery callback
        transport.onPeripheralDiscovered = { peripheral, rssi in
            handleDiscoveredPeripheral(peripheral: peripheral, rssi: rssi)
        }

        scanTransport = transport
        isScanning = true

        // Start scanning
        transport.connect()
    }

    /// Stop BLE scanning.
    private func stopScanning() {
        scanTransport?.disconnect()
        scanTransport = nil
        isScanning = false
    }

    /// Toggle scanning state.
    private func toggleScanning() {
        if isScanning {
            stopScanning()
        } else {
            startScanning()
        }
    }

    // MARK: - Device Discovery

    /// Handle a discovered BLE peripheral.
    ///
    /// - Parameters:
    ///   - peripheral: The discovered peripheral.
    ///   - rssi: Signal strength.
    private func handleDiscoveredPeripheral(peripheral: CBPeripheral, rssi: NSNumber) {
        // Skip unnamed peripherals
        guard let name = peripheral.name, !name.isEmpty else {
            return
        }

        let peripheralId = peripheral.identifier
        let rssiInt = rssi.intValue
        let now = Date()

        // Check for existing device
        if let index = discoveredDevices.firstIndex(where: { $0.peripheralId == peripheralId }) {
            // RSSI throttling: skip if last update was < 1s ago
            if let lastUpdate = lastUpdateTime[peripheralId],
               now.timeIntervalSince(lastUpdate) < 1.0 {
                return
            }

            // RSSI delta: skip if change is < 5 dBm
            let existingRssi = discoveredDevices[index].rssi
            if abs(rssiInt - existingRssi) < 5 {
                return
            }

            // Update existing device
            discoveredDevices[index].rssi = rssiInt
            discoveredDevices[index].lastSeen = now
            lastUpdateTime[peripheralId] = now
        } else {
            // Add new device
            let device = DiscoveredDevice(
                peripheralId: peripheralId,
                name: name,
                rssi: rssiInt,
                lastSeen: now
            )
            discoveredDevices.append(device)
            lastUpdateTime[peripheralId] = now
        }

        // Sort by RSSI descending (strongest first)
        discoveredDevices.sort { $0.rssi > $1.rssi }
    }

    // MARK: - Device Selection

    /// Select a device and dismiss the sheet.
    ///
    /// - Parameter device: The selected device.
    private func selectDevice(_ device: DiscoveredDevice) {
        viewModel.configDeviceName = device.name
        stopScanning()
        dismiss()
    }
}

#else

// MARK: - macOS Stub

/// Stub implementation for platforms without CoreBluetooth.
@available(iOS 17.0, macOS 14.0, *)
struct BLEDevicePickerSheet: View {
    @Bindable var viewModel: InterfaceManagementViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("BLE not available on this platform")
                .foregroundStyle(.secondary)

            Button("Close") {
                dismiss()
            }
        }
        .padding()
    }
}

#endif
