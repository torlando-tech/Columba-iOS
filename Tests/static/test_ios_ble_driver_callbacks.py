#!/usr/bin/env python3
"""Runtime callback regressions for the embedded iOS BLE driver."""

from enum import Enum
import importlib.util
from pathlib import Path
import sys
import types
import unittest


ROOT = Path(__file__).resolve().parents[2]
DRIVER_PATH = ROOT / "app/ble/IOSBLEDriver.py"


class DriverState(Enum):
    IDLE = "idle"


class BLEDriverInterface:
    def __init__(self) -> None:
        self.on_device_discovered = None
        self.on_device_connected = None
        self.on_device_disconnected = None
        self.on_data_received = None
        self.on_mtu_negotiated = None
        self.on_identity_received = None
        self.on_address_changed = None
        self.on_duplicate_identity_detected = None
        self.on_error = None


class IOSBLEDriverCallbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        rns = types.ModuleType("RNS")
        setattr(rns, "LOG_ERROR", 3)
        setattr(rns, "LOG_WARNING", 4)
        setattr(rns, "LOG_DEBUG", 7)
        setattr(rns, "log", lambda *args, **kwargs: None)
        sys.modules["RNS"] = rns

        package = types.ModuleType("ble_reticulum")
        package.__path__ = []
        sys.modules["ble_reticulum"] = package

        bluetooth_driver = types.ModuleType("ble_reticulum.bluetooth_driver")
        setattr(bluetooth_driver, "BLEDriverInterface", BLEDriverInterface)
        setattr(bluetooth_driver, "BLEDevice", object)
        setattr(bluetooth_driver, "DriverState", DriverState)
        sys.modules["ble_reticulum.bluetooth_driver"] = bluetooth_driver

        bridge = types.ModuleType("rns_bridge")
        callbacks = {}
        setattr(bridge, "callbacks", callbacks)
        setattr(
            bridge,
            "set_ble_callback",
            lambda slot, callback: callbacks.__setitem__(slot, callback),
        )
        sys.modules["rns_bridge"] = bridge

        spec = importlib.util.spec_from_file_location("ios_ble_driver_callback_test", DRIVER_PATH)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cls.Driver = module.IOSBLEDriver

    def test_migrated_peer_survives_old_disconnect_and_reused_address_disconnects(self) -> None:
        driver = self.Driver()
        disconnected = []
        migrations = []
        driver.on_device_connected = lambda address, identity: None
        driver.on_device_disconnected = disconnected.append
        driver.on_address_changed = lambda old, new, identity: migrations.append(
            (old, new, identity)
        )

        old_address = "11111111-1111-1111-1111-111111111111"
        new_address = "22222222-2222-2222-2222-222222222222"
        first_identity = b"a" * 16

        driver._raw_on_device_connected(old_address, first_identity)
        driver._raw_on_address_changed(old_address, new_address, first_identity.hex())
        driver._raw_on_device_disconnected(old_address)

        self.assertEqual([(old_address, new_address, first_identity.hex())], migrations)
        self.assertEqual([old_address], disconnected)
        self.assertEqual([new_address], driver.connected_peers)
        self.assertEqual(first_identity.hex(), driver._address_to_identity[new_address])

        # Reuse the old CoreBluetooth address for another connection. Its real
        # disconnect must not be swallowed by a stale dedupe marker.
        second_identity = b"b" * 16
        driver._raw_on_device_connected(old_address, second_identity)
        driver._raw_on_device_disconnected(old_address)

        self.assertEqual([old_address, old_address], disconnected)
        self.assertEqual([new_address], driver.connected_peers)
        self.assertEqual(first_identity.hex(), driver._address_to_identity[new_address])


if __name__ == "__main__":
    unittest.main()
