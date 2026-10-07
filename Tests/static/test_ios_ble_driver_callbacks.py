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

    def test_identity_received_reconnect_under_new_address_dedups(self) -> None:
        """A peer reconnecting under a fresh randomized GATT address surfaces
        its identity again via ``on_identity_received``. The driver re-points the
        address<->identity mapping immediately, but (P1 #2) DEFERS the
        ``on_address_changed`` route migration until the NEW address has
        actually connected: firing it the instant identity is seen would re-route
        to an address whose GATT link may never come up (the handshake can fail
        after identity is learned), leaving messages routed to a dead link.

        So: identity at a new (not-yet-connected) address -> no migration yet;
        once ``on_device_connected`` confirms the new link -> the migration
        fires and the old address is evicted (the upstream ``BLEInterface`` then
        migrates address_to_identity / peer_address / fragmenter keys). Without
        the dedup, the upstream map accumulates one entry per reconnect and RNS
        keeps routing announces to stale dead addresses (SEND-NO-TARGET).
        """
        driver = self.Driver()
        migrations = []
        driver.on_device_connected = lambda address, identity: None
        driver.on_address_changed = lambda old, new, identity: migrations.append(
            (old, new, identity)
        )

        identity = b"c" * 16
        identity_hex = identity.hex()
        old_address = "11111111-1111-1111-1111-111111111111"
        new_address = "22222222-2222-2222-2222-222222222222"

        # First connection: identity learned at the old GATT address.
        driver._raw_on_device_connected(old_address, identity)

        # Reconnect under a new randomized GATT address; the Swift bridge
        # re-surfaces the identity as a fresh on_identity_received. The new
        # address is NOT yet connected, so the route migration is deferred.
        driver._raw_on_identity_received(new_address, identity_hex)

        # Mapping is re-pointed to the new address, but the upstream migration
        # callback has NOT fired yet (deferred until the new link connects).
        self.assertEqual([], migrations)
        self.assertEqual(new_address, driver._identity_to_address[identity_hex])
        self.assertEqual(identity_hex, driver._address_to_identity.get(new_address))

        # The new link comes up -> the deferred migration fires and evicts the
        # old address so the wheel routes to the live address.
        driver._raw_on_device_connected(new_address, identity)

        self.assertEqual([(old_address, new_address, identity_hex)], migrations)
        self.assertEqual(new_address, driver._identity_to_address[identity_hex])
        self.assertEqual(identity_hex, driver._address_to_identity.get(new_address))
        self.assertNotIn(old_address, driver._address_to_identity)

    def test_identity_received_new_address_connect_fails_no_migration(self) -> None:
        """P1 #2: if the new address reports identity but its GATT connect then
        FAILS (never fires on_device_connected, the link drops), the route must
        NOT have moved to the new address - the old address still owns it. The
        deferred migration is simply dropped on disconnect, no on_address_changed
        fires, and no stale pending entry leaks."""
        driver = self.Driver()
        migrations = []
        driver.on_device_connected = lambda address, identity: None
        driver.on_address_changed = lambda old, new, identity: migrations.append(
            (old, new, identity)
        )

        identity = b"c" * 16
        identity_hex = identity.hex()
        old_address = "11111111-1111-1111-1111-111111111111"
        new_address = "22222222-2222-2222-2222-222222222222"

        driver._raw_on_device_connected(old_address, identity)
        # Identity surfaces for a new address that then fails to connect.
        driver._raw_on_identity_received(new_address, identity_hex)
        driver._raw_on_device_disconnected(new_address)

        # No migration ever fired; the old address is untouched.
        self.assertEqual([], migrations)
        self.assertIn(old_address, driver.connected_peers)
        self.assertNotIn(new_address, driver.connected_peers)
        self.assertEqual(0, len(driver._pending_address_migrations))

    def test_identity_received_distinct_identities_both_kept(self) -> None:
        """Guard against over-eager dedup: two *different* identities at two
        addresses must both be retained; no on_address_changed is emitted."""
        driver = self.Driver()
        migrations = []
        driver.on_device_connected = lambda address, identity: None
        driver.on_address_changed = lambda old, new, identity: migrations.append(
            (old, new, identity)
        )

        identity_a = b"a" * 16
        identity_b = b"b" * 16
        addr_a = "11111111-1111-1111-1111-111111111111"
        addr_b = "22222222-2222-2222-2222-222222222222"

        driver._raw_on_device_connected(addr_a, identity_a)
        driver._raw_on_identity_received(addr_b, identity_b.hex())

        self.assertEqual([], migrations)
        self.assertEqual(addr_a, driver._identity_to_address[identity_a.hex()])
        self.assertEqual(addr_b, driver._identity_to_address[identity_b.hex()])
        self.assertEqual(identity_a.hex(), driver._address_to_identity[addr_a])
        self.assertEqual(identity_b.hex(), driver._address_to_identity[addr_b])


if __name__ == "__main__":
    unittest.main()
