//
//  ModelBBLEService.swift
//  ColumbaApp
//
//  App side of the Model B BLE seam. CoreBluetooth can't run in the Network
//  Extension, so the app hosts the REAL reticulum-swift `CoreBluetoothBLEDriver`
//  and an `AppGroupBLEServer` that bridges it to the NE's `BLEInterface` over the
//  App-Group (the NE drives scan/advertise/connect via the seam; this side just
//  runs the radio + forwards events back). See `ble_to_ne_driver_abstraction_plan`.
//
//  IMPORTANT: this file `import ReticulumSwift` (NOT RNSAPI) so `CoreBluetoothBLEDriver`
//  resolves to the real driver — `AppServices` uses RNSAPI's Compat stubs, hence the
//  separate file (Swift imports are per-file).
//
//  Single instance + idempotent start: `CoreBluetoothBLEDriver` registers a CB
//  state-restoration identifier, so there must be exactly one. Under Model B this
//  REPLACES `SwiftBLEBridge` as the app's CoreBluetooth owner — the caller gates out
//  `SwiftBLEBridge.restoreAtLaunch()` when Model B is active so the two CB stacks
//  don't fight over the same GATT service.
//

import Foundation
import CoreBluetooth
import ReticulumSwift

public final class ModelBBLEService: @unchecked Sendable {

    public static let shared = ModelBBLEService()

    static let userOptInKey = "model_b_ble_user_opt_in"

    static var isUserOptedIn: Bool {
        isUserOptedIn(in: .standard)
    }

    static func isUserOptedIn(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: userOptInKey)
    }

    static func recordUserOptIn(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: userOptInKey)
    }

    /// Decide whether the app-side Model B CoreBluetooth host may start without
    /// constructing a manager. Existing users who already granted Bluetooth are
    /// migrated to the explicit opt-in key so an upgrade does not silently disable BLE.
    static var shouldStart: Bool {
        shouldStart(isBluetoothAuthorized: CBCentralManager.authorization == .allowedAlways)
    }

    static func shouldStart(
        isBluetoothAuthorized: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if isUserOptedIn(in: defaults) {
            return true
        }
        guard isBluetoothAuthorized else {
            return false
        }
        recordUserOptIn(in: defaults)
        return true
    }

    private init() {}

    private let lock = NSLock()
    private var driver: CoreBluetoothBLEDriver?
    private var transport: AppGroupBLESeamTransport?
    private var server: AppGroupBLEServer?

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return driver != nil }

    /// Construct + start the CoreBluetooth driver and the App-Group server. Idempotent.
    /// - Parameter identityHash: the 16-byte transport identity (the same one the NE
    ///   uses for its `BLEInterface`), so the GATT identity characteristic matches.
    public func start(identityHash: Data) {
        lock.lock(); defer { lock.unlock() }
        guard driver == nil else { return }
        precondition(identityHash.count == 16, "BLE transport identity must be 16 bytes")

        let drv = CoreBluetoothBLEDriver(identityHash: identityHash)
        let tx = AppGroupBLESeamTransport(role: .app)
        tx.start()
        let srv = AppGroupBLEServer(transport: tx, driver: drv, log: { DiagLog.log($0) })
        srv.start()
        // No scan/advertise here: the NE's BLEInterface.connect() drives those over
        // the seam (so the two processes stay coordinated). This side only runs the
        // radio + relays events.

        self.driver = drv
        self.transport = tx
        self.server = srv
        DiagLog.log("[BLE] Model B BLE service started (CoreBluetoothBLEDriver + AppGroupBLEServer)")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        driver?.shutdown()
        transport?.stop()
        driver = nil
        transport = nil
        server = nil
        DiagLog.log("[BLE] Model B BLE service stopped")
    }
}
