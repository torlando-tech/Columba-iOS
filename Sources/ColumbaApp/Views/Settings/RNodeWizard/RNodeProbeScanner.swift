//
//  RNodeProbeScanner.swift
//  ColumbaApp
//
//  Lightweight CoreBluetooth scanner for the RNode wizard.
//  Scans for BLE peripherals, connects, discovers NUS service,
//  and sends the RNode detect probe. No restore identifier,
//  no auto-reconnect — just simple scan and probe.
//

#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import os
import ReticulumSwift

/// Lightweight BLE scanner for the RNode configuration wizard.
///
/// Unlike `BLETransport`, this class:
/// - Does NOT use a restore identifier (avoids CBCentralManager conflicts)
/// - Does NOT auto-reconnect on failure
/// - Supports scan → connect → probe → disconnect lifecycle
@available(iOS 17.0, macOS 14.0, *)
final class RNodeProbeScanner: NSObject {

    // MARK: - Callbacks

    /// Called when a peripheral is discovered during scanning.
    var onDiscovered: ((CBPeripheral, NSNumber) -> Void)?

    /// Called when state changes during a probe attempt.
    var onProbeResult: ((ProbeResult) -> Void)?

    enum ProbeResult: CustomStringConvertible {
        case connecting
        case connected
        case servicesFound(Int)
        case characteristicsReady
        case detectSent
        case detectWriteConfirmed
        case detectWriteFailed(String)
        case detectResponseReceived
        case failed(String)

        var description: String {
            switch self {
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .servicesFound(let n): return "services(\(n))"
            case .characteristicsReady: return "chars ready"
            case .detectSent: return "detect sent"
            case .detectWriteConfirmed: return "write OK"
            case .detectWriteFailed(let e): return "write FAIL: \(e)"
            case .detectResponseReceived: return "VERIFIED"
            case .failed(let msg): return "FAILED: \(msg)"
            }
        }
    }

    // MARK: - Properties

    private var centralManager: CBCentralManager!
    private var connectingPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var isScanning = false
    private var hasSentDetectProbe = false
    private var pairingTriggered = false
    private var nusDiscovered = false
    private let logger = Logger(subsystem: "com.columba.app", category: "RNodeProbe")

    /// File-based diagnostic log (readable via idevice tools).
    private static let diagURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("rnode_probe.log")
    }()

    private func diag(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        logger.error("[PROBE] \(msg, privacy: .public)")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.diagURL.path) {
                if let handle = try? FileHandle(forWritingTo: Self.diagURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.diagURL)
            }
        }
    }

    // NUS UUIDs
    private let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let nusTxCharUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private let nusRxCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: - Init

    override init() {
        super.init()
        // No restore identifier — avoids conflicts with other CBCentralManagers
        centralManager = CBCentralManager(delegate: self, queue: nil)
        diag("RNodeProbeScanner initialized")
    }

    // MARK: - Scan

    func startScan() {
        guard centralManager.state == .poweredOn else {
            // Will start when powered on
            isScanning = true
            return
        }
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        isScanning = false
        centralManager.stopScan()
    }

    // MARK: - Probe

    /// Connect to a peripheral and send the RNode detect probe.
    func probe(_ peripheral: CBPeripheral) {
        centralManager.stopScan()
        connectingPeripheral = peripheral
        peripheral.delegate = self
        hasSentDetectProbe = false
        pairingTriggered = false
        nusDiscovered = false
        onProbeResult?(.connecting)
        diag("Connecting to \(peripheral.name ?? "?")")
        centralManager.connect(peripheral, options: nil)
    }

    /// Cancel any in-progress probe and resume scanning.
    func cancelProbe() {
        diag("cancelProbe called, connectingPeripheral=\(connectingPeripheral?.name ?? "nil"), isScanning=\(isScanning)")
        if let p = connectingPeripheral {
            centralManager.cancelPeripheralConnection(p)
            connectingPeripheral = nil
        }
        rxCharacteristic = nil
        if isScanning {
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    /// Shut down completely.
    func shutdown() {
        stopScan()
        if let p = connectingPeripheral {
            centralManager.cancelPeripheralConnection(p)
            connectingPeripheral = nil
        }
        rxCharacteristic = nil
        txCharacteristic = nil
    }

    // MARK: - Private

    private func sendDetectProbe() {
        guard let rx = rxCharacteristic, let peripheral = connectingPeripheral else {
            diag("No RX characteristic to send detect")
            onProbeResult?(.failed("No RX characteristic"))
            return
        }
        let detectCommand = Data([
            KISS.FEND, RNodeConstants.CMD_DETECT, RNodeConstants.DETECT_REQ, KISS.FEND
        ])
        // Always use .withResponse so we get didWriteValueFor callback (catches encryption errors)
        let writeType: CBCharacteristicWriteType = rx.properties.contains(.write) ? .withResponse : .withoutResponse
        diag("Sending detect probe (\(detectCommand.count) bytes), writeType=\(writeType == .withResponse ? "withResponse" : "withoutResponse"), props=\(rx.properties.rawValue)")
        hasSentDetectProbe = true
        peripheral.writeValue(detectCommand, for: rx, type: writeType)
        onProbeResult?(.detectSent)
    }
}

// MARK: - CBCentralManagerDelegate

@available(iOS 17.0, macOS 14.0, *)
extension RNodeProbeScanner: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        diag("Central state: \(central.state.rawValue)")
        if central.state == .poweredOn && isScanning {
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscovered?(peripheral, RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        diag("Connected to \(peripheral.name ?? "?")")
        onProbeResult?(.connected)
        // Discover ALL services — we need to find characteristics that require
        // encryption to trigger iOS BLE pairing (not just NUS).
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let desc = error?.localizedDescription ?? "Unknown"
        diag("Failed to connect: \(desc)")
        connectingPeripheral = nil
        onProbeResult?(.failed("Connection failed: \(desc)"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        diag("Disconnected, error=\(error?.localizedDescription ?? "none")")
        connectingPeripheral = nil
        rxCharacteristic = nil
    }
}

// MARK: - CBPeripheralDelegate

@available(iOS 17.0, macOS 14.0, *)
extension RNodeProbeScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            diag("Service discovery failed: \(error.localizedDescription)")
            onProbeResult?(.failed("Service discovery failed"))
            cancelProbe()
            return
        }

        let services = peripheral.services ?? []
        let serviceList = services.map { $0.uuid.uuidString }
        diag("ALL services found: \(serviceList)")
        onProbeResult?(.servicesFound(serviceList.count))

        guard services.contains(where: { $0.uuid == nusServiceUUID }) else {
            diag("NUS service not found on device")
            onProbeResult?(.failed("Not an RNode (NUS service missing)"))
            cancelProbe()
            return
        }

        // Discover characteristics for ALL services — reading non-NUS
        // characteristics may trigger iOS BLE pairing if they require encryption.
        for service in services {
            diag("Discovering chars for service \(service.uuid.uuidString)...")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            diag("Char discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }

        let chars = service.characteristics ?? []
        diag("Service \(service.uuid.uuidString) chars: \(chars.map { "\($0.uuid.uuidString) props=\($0.properties.rawValue)" })")

        if service.uuid == nusServiceUUID {
            // NUS service — save TX/RX characteristics
            if let tx = chars.first(where: { $0.uuid == nusTxCharUUID }) {
                txCharacteristic = tx
                diag("TX char found, props=\(tx.properties.rawValue)")
            }
            if let rx = chars.first(where: { $0.uuid == nusRxCharUUID }) {
                rxCharacteristic = rx
                diag("RX char found, props=\(rx.properties.rawValue)")
            }

            guard rxCharacteristic != nil else {
                onProbeResult?(.failed("Missing RX characteristic"))
                cancelProbe()
                return
            }
            nusDiscovered = true
            onProbeResult?(.characteristicsReady)
        }

        // Try reading ALL readable characteristics on any service.
        // If any requires encryption, iOS will trigger the pairing dialog.
        for char in chars {
            if char.properties.contains(.read) {
                diag("Reading \(char.uuid.uuidString) (service \(service.uuid.uuidString)) to probe encryption...")
                peripheral.readValue(for: char)
            }
        }

        // If NUS is discovered and we've already attempted reads on other services,
        // check if we should proceed directly (no pairing needed).
        if nusDiscovered && !pairingTriggered {
            // Give a short delay for pairing dialog to appear, then proceed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, !self.hasSentDetectProbe, self.nusDiscovered else { return }
                self.diag("No pairing triggered — enabling TX notifications and sending detect")
                if let tx = self.txCharacteristic {
                    peripheral.setNotifyValue(true, for: tx)
                } else {
                    self.sendDetectProbe()
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            diag("Write failed: \(error.localizedDescription)")
            onProbeResult?(.detectWriteFailed(error.localizedDescription))
        } else {
            diag("Write confirmed OK")
            onProbeResult?(.detectWriteConfirmed)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            diag("Notification setup failed for \(characteristic.uuid): \(error.localizedDescription)")
            onProbeResult?(.failed("Notification setup failed: \(error.localizedDescription)"))
            return
        }
        diag("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")

        // TX notifications confirmed — now safe to send detect probe
        if characteristic.uuid == nusTxCharUUID && characteristic.isNotifying {
            diag("TX notifications ready — sending detect probe")
            sendDetectProbe()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let errStr = error.localizedDescription
            diag("Read/notify error for \(characteristic.uuid.uuidString): \(errStr)")
            // "Insufficient Authentication" or "Insufficient Encryption" means iOS
            // should be initiating pairing — mark it so we wait.
            if errStr.contains("Authentication") || errStr.contains("Encryption") || errStr.contains("auth") {
                diag(">>> Pairing should be triggered by iOS! Waiting for user to enter PIN...")
                pairingTriggered = true
                onProbeResult?(.failed("Pairing required — enter PIN on dialog"))
            }
            return
        }

        // If we haven't sent detect yet, this is a read result from encryption probing
        if !hasSentDetectProbe {
            let svc = characteristic.service?.uuid.uuidString ?? "?"
            diag("Read OK: \(characteristic.uuid.uuidString) (svc \(svc)) = \(characteristic.value?.count ?? 0) bytes")
            return
        }

        guard let data = characteristic.value, !data.isEmpty else {
            diag("didUpdateValue: empty data")
            return
        }

        diag("Received \(data.count) bytes: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // Check for detect response
        if data.count >= 2 {
            for i in 0..<(data.count - 1) {
                if data[i] == RNodeConstants.CMD_DETECT && data[i + 1] == RNodeConstants.DETECT_RESP {
                    diag("Detect response received — RNode verified!")
                    onProbeResult?(.detectResponseReceived)
                    centralManager.cancelPeripheralConnection(peripheral)
                    connectingPeripheral = nil
                    rxCharacteristic = nil
                    txCharacteristic = nil
                    return
                }
            }
        }
        diag("Data did not contain detect response")
    }
}

#endif
