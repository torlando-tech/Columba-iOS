"""Columba iOS BLE interface — port of Columba Android's ble_modules.

Two modules:
  - ios_ble_interface.IOSBLEInterface  — thin subclass of upstream BLEInterface
  - ios_ble_driver.IOSBLEDriver        — implements BLEDriverInterface, bridges to Swift

The Swift `SwiftBLEBridge` is handed to Python via `rns_bridge.set_ble_bridge`
during app startup; `IOSBLEDriver` pulls the bridge handle from there.
"""
