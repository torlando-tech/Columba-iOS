//
//  CoreBluetoothRestoreIdentifiers.swift
//  RNSAPI
//
//  Process-wide CoreBluetooth state-restoration identifier registry.
//

import Foundation

/// Stable identifiers for every CoreBluetooth manager that can coexist in the
/// Columba app process. Each manager must use a unique value or CoreBluetooth
/// can restore preserved peripherals to the wrong owner after a relaunch.
///
/// These values are persistence keys and must not be renamed casually. The
/// RNode value mirrors `ReticulumSwift.BLEConstants.RESTORE_IDENTIFIER_KEY`;
/// the Model B native tests enforce that dependency boundary.
public enum CoreBluetoothRestoreIdentifiers {
    /// Direct BLE mesh central owned by SwiftBLEBridge.
    public static let meshCentral = "network.columba.ble.central"

    /// Direct BLE mesh peripheral manager owned by SwiftBLEBridge.
    public static let meshPeripheral = "network.columba.ble.peripheral"

    /// RNode/NUS central owned by ReticulumSwift.BLETransport.
    public static let rnodeCentral = "com.columba.ble.central"

    public static let all = [meshCentral, meshPeripheral, rnodeCentral]

    /// Fails closed when a future manager accidentally reuses an identifier.
    public static var areUnique: Bool {
        Set(all).count == all.count
    }
}
