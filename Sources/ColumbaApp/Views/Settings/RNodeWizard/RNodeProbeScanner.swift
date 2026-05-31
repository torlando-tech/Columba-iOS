#if COLUMBA_RNODE_ENABLED
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
import RNSAPI
import CoreBluetooth
import os

/// KISS framing + the subset of RNode command bytes the wizard's BLE probe
/// needs to verify a peripheral is an RNode. Values are the RNode/KISS
/// protocol constants — source of truth is `app/rnode/IOSRNodeInterface.py`'s
/// `KISS` class (and Android's `rnode_interface.py`), kept byte-identical so
/// the detect handshake interoperates.
private enum KISS {
    static let FEND: UInt8 = 0xC0
}

private enum RNodeConstants {
    static let CMD_DETECT: UInt8 = 0x08
    static let DETECT_REQ: UInt8 = 0x73
    static let DETECT_RESP: UInt8 = 0x46
}

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
    /// True after the first pairing-required error is seen. Persists across
    /// auto-reconnects so we skip the encrypted-char reads that caused the
    /// pairing loop and go straight to TX-notify → detect on the next connect.
    private var pairingAttempted = false
    /// Set when we want didDisconnectPeripheral to auto-reconnect (e.g., TX notify
    /// timed out on first connect — ESP32 sometimes needs a second attempt).
    private var needsReconnect = false
    /// Set after we auto-retry following a sent-but-unanswered detect probe.
    /// Prevents infinite retry loops — only one detect-retry per probe() call.
    private var detectRetried = false
    /// Incremented on each probe() call and each auto-reconnect. Async closures
    /// capture their generation and no-op if it no longer matches, preventing
    /// stale 3s notify timeouts from firing on subsequent reconnect attempts.
    private var probeGeneration = 0
    private let logger = Logger(subsystem: "network.columba.Columba", category: "RNodeProbe")

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
        // Cancel any existing probe (could be connecting to a different device)
        if let existing = connectingPeripheral, existing != peripheral {
            diag("Cancelling previous probe for \(existing.name ?? "?")")
            centralManager.cancelPeripheralConnection(existing)
        }
        centralManager.stopScan()
        connectingPeripheral = peripheral
        peripheral.delegate = self
        hasSentDetectProbe = false
        pairingTriggered = false
        pairingAttempted = false
        nusDiscovered = false
        needsReconnect = false
        detectRetried = false
        probeGeneration += 1
        onProbeResult?(.connecting)
        diag("Connecting to \(peripheral.name ?? "?")")
        centralManager.connect(peripheral, options: nil)
    }

    /// Cancel any in-progress probe and resume scanning.
    func cancelProbe() {
        diag("cancelProbe called, connectingPeripheral=\(connectingPeripheral?.name ?? "nil"), isScanning=\(isScanning)")
        probeGeneration += 1  // invalidate any pending closures
        if let p = connectingPeripheral {
            centralManager.cancelPeripheralConnection(p)
            connectingPeripheral = nil
        }
        rxCharacteristic = nil
        txCharacteristic = nil
        nusDiscovered = false
        hasSentDetectProbe = false
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
        // Ignore stale connections for peripherals we're no longer probing.
        guard peripheral == connectingPeripheral else {
            diag("Ignoring connect for \(peripheral.name ?? "?") — not our probe target, cancelling")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        diag("Connected to \(peripheral.name ?? "?") pairingAttempted=\(pairingAttempted)")
        onProbeResult?(.connected)
        // Always discover all services — discoverServices(nil) uses iOS's cached
        // GATT profile (~0.4s), while discoverServices([specificUUID]) bypasses
        // the cache and forces a fresh BLE exchange (~11s), exceeding the RNode
        // firmware's idle connection timeout.
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == connectingPeripheral else { return }
        let desc = error?.localizedDescription ?? "Unknown"
        diag("Failed to connect: \(desc)")
        connectingPeripheral = nil
        // CBError.peerRemovedPairingInformation (code 14): this iPhone still holds
        // a BLE bond for the RNode, but the device forgot its side (re-flashed /
        // reset / bond table cleared). iOS does NOT re-show the pairing prompt in
        // this state — it just fails the connect — and there is no API to drop the
        // stale bond, so the user has to remove it in Settings. Surface that
        // instead of the cryptic CoreBluetooth string.
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            let name = peripheral.name ?? "this RNode"
            onProbeResult?(.failed(
                "\(name) has a stale Bluetooth pairing on this iPhone. Open Settings ▸ Bluetooth, "
                + "tap the ⓘ next to \(name), choose “Forget This Device”, then scan again."
            ))
        } else {
            onProbeResult?(.failed("Connection failed: \(desc)"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == connectingPeripheral else {
            diag("Ignoring disconnect for \(peripheral.name ?? "?") — not our target")
            return
        }
        diag("Disconnected, error=\(error?.localizedDescription ?? "none"), pairingTriggered=\(pairingTriggered), hasSentDetect=\(hasSentDetectProbe), detectRetried=\(detectRetried)")

        // If we sent the detect probe but the firmware disconnected before responding
        // (common on first connect after forgetting — bond is established during the
        // 6s CCCD wait, then firmware times out before we get the detect response),
        // schedule one auto-retry. The second connect confirms CCCD in ~60ms and
        // the detect response arrives immediately.
        if hasSentDetectProbe && !detectRetried {
            needsReconnect = true
            detectRetried = true
        }

        // Auto-reconnect when:
        // (a) pairing was triggered — iOS may disconnect after bonding, then we retry
        // (b) needsReconnect — TX notify timed out on first connect (ESP32 quirk),
        //     retry once and it usually works the second time.
        if pairingTriggered || needsReconnect {
            let wasPairing = pairingTriggered
            needsReconnect = false
            hasSentDetectProbe = false
            nusDiscovered = false
            rxCharacteristic = nil
            txCharacteristic = nil
            pairingTriggered = false
            connectingPeripheral = peripheral
            peripheral.delegate = self
            probeGeneration += 1
            let gen = probeGeneration
            onProbeResult?(.connecting)
            // When pairing was triggered, delay the reconnect so iOS has time to
            // process the bond before we try again. Immediate reconnects can race
            // with the pairing negotiation and cause the dialog to loop.
            let delay: TimeInterval = wasPairing ? 2.0 : 0.0
            diag("Auto-reconnecting in \(delay)s after \(wasPairing ? "pairing" : "notify timeout") disconnect...")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.probeGeneration == gen else { return }
                self.centralManager.connect(peripheral, options: nil)
            }
            return
        }

        probeGeneration += 1  // invalidate any pending closures
        connectingPeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        nusDiscovered = false
    }
}

// MARK: - CBPeripheralDelegate

@available(iOS 17.0, macOS 14.0, *)
extension RNodeProbeScanner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == connectingPeripheral else { return }
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

        // Discover characteristics — on first connect probe ALL services to trigger
        // iOS BLE pairing if needed; on reconnect skip non-NUS services (encryption
        // already probed) to avoid unnecessary latency.
        for service in services {
            if pairingAttempted && service.uuid != nusServiceUUID {
                diag("Skipping char discovery for \(service.uuid.uuidString) on reconnect")
                continue
            }
            diag("Discovering chars for service \(service.uuid.uuidString)...")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == connectingPeripheral else { return }
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

        // Try reading ALL readable characteristics on any service to trigger
        // the iOS BLE pairing dialog — but only on the FIRST connect attempt.
        // After pairing has been attempted, skip these reads so the auto-reconnect
        // goes straight to TX-notify → detect without re-triggering the dialog loop.
        if !pairingAttempted {
            for char in chars {
                if char.properties.contains(.read) {
                    diag("Reading \(char.uuid.uuidString) (service \(service.uuid.uuidString)) to probe encryption...")
                    peripheral.readValue(for: char)
                }
            }
        }

        // If NUS is discovered and we've already attempted reads on other services,
        // check if we should proceed directly (no pairing needed).
        if nusDiscovered && !pairingTriggered {
            // Capture the generation so stale closures from previous connection
            // attempts don't fire when we reconnect (same peripheral object reused).
            let gen = probeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.probeGeneration == gen,
                      !self.hasSentDetectProbe, self.nusDiscovered else { return }
                self.diag("No pairing triggered — enabling TX notifications")
                if let tx = self.txCharacteristic {
                    peripheral.setNotifyValue(true, for: tx)
                    // Wait for didUpdateNotificationStateFor to confirm CCCD before
                    // sending detect — the firmware sends its DETECT_RESP as a
                    // notification, so CCCD must be confirmed before we send the probe.
                } else {
                    // No TX char — send detect directly (won't receive response)
                    self.sendDetectProbe()
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let errStr = error.localizedDescription
            diag("Write failed: \(errStr)")
            // Auth/encryption errors mean iOS is negotiating a bond — the pairing flow
            // will handle recovery via didUpdateNotificationStateFor. Don't cancel.
            if errStr.contains("Authentication") || errStr.contains("Encryption") || errStr.contains("auth") {
                diag("Write auth error — pairing in progress, ignoring")
                return
            }
            onProbeResult?(.detectWriteFailed(errStr))
        } else {
            diag("Write confirmed OK")
            onProbeResult?(.detectWriteConfirmed)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let errStr = error.localizedDescription
            diag("Notification setup failed for \(characteristic.uuid): \(errStr)")
            if errStr.contains("Authentication") || errStr.contains("Encryption") || errStr.contains("auth") {
                // TX notify requires a BLE bond (pairing). Set both flags:
                // - pairingTriggered: so didDisconnectPeripheral delays 2s then reconnects
                // - pairingAttempted: so subsequent connections skip the DIS/Battery reads
                //   (they don't require auth — only the notify does)
                diag("Notify requires auth — pairingTriggered=true, pairingAttempted=\(pairingAttempted)")
                pairingTriggered = true
                if !pairingAttempted {
                    pairingAttempted = true
                    // Notify UI once so the pairing hint appears
                    onProbeResult?(.failed("Pairing required — enter PIN on dialog"))
                }
            } else {
                onProbeResult?(.failed("Notification setup failed: \(errStr)"))
            }
            return
        }
        diag("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")

        // TX notifications confirmed — send detect probe if not already sent
        if characteristic.uuid == nusTxCharUUID && characteristic.isNotifying && !hasSentDetectProbe {
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
                diag(">>> Pairing triggered by iOS! (pairingAttempted=\(pairingAttempted))")
                pairingTriggered = true
                if !pairingAttempted {
                    pairingAttempted = true
                    onProbeResult?(.failed("Pairing required — enter PIN on dialog"))
                }
                // Schedule a retry in case iOS upgrades the connection in-place
                // without disconnecting (no didDisconnect callback in that case).
                let gen = probeGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, self.probeGeneration == gen,
                          !self.hasSentDetectProbe,
                          let p = self.connectingPeripheral, let tx = self.txCharacteristic else { return }
                    self.diag("Retrying TX notify after read auth error")
                    p.setNotifyValue(true, for: tx)
                }
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
#endif
