#!/usr/bin/env python3
"""Behavioral tests for the ctypes side of the shipping iOS RNode bridge."""

import ctypes
import importlib.util
from pathlib import Path
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "app/rnode/IOSRNodeDriver.py"


class FakeFunction:
    def __init__(self, implementation):
        self.implementation = implementation
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        return self.implementation(*args)


class FakeNativeLibrary:
    def __init__(self):
        self.state = 0
        self.disconnect_count = 0
        self.online_values = []
        self.writes = []
        self.inbound = bytearray()
        self.columba_rnode_connect = FakeFunction(self.connect)
        self.columba_rnode_disconnect = FakeFunction(self.disconnect)
        self.columba_rnode_state = FakeFunction(lambda: self.state)
        self.columba_rnode_read = FakeFunction(self.read)
        self.columba_rnode_write = FakeFunction(self.write)
        self.columba_rnode_set_online = FakeFunction(self.set_online)

    def connect(self, _name):
        self.state = 2
        return 0

    def disconnect(self):
        self.disconnect_count += 1
        self.state = 0
        return 0

    def read(self, output, capacity):
        count = min(int(capacity), len(self.inbound))
        for index in range(count):
            output[index] = self.inbound[index]
        del self.inbound[:count]
        return count

    def write(self, data, count):
        self.writes.append(bytes(data[: int(count)]))
        return int(count)

    def set_online(self, value):
        self.online_values.append(int(value))
        return 0


def load_driver(native):
    spec = importlib.util.spec_from_file_location("ios_rnode_driver_under_test", DRIVER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    with mock.patch.object(ctypes, "CDLL", return_value=native):
        spec.loader.exec_module(module)
    return module


class IOSRNodeDriverTests(unittest.TestCase):
    def test_connect_read_write_online_and_disconnect_transition(self):
        native = FakeNativeLibrary()
        module = load_driver(native)
        driver = module.IOSRNodeDriver()

        self.assertTrue(driver.connect("RNode 1234", "ble"))
        transitions = []
        driver.setOnConnectionStateChanged(
            lambda connected, name: transitions.append((connected, name))
        )
        self.assertEqual(transitions, [(True, "RNode 1234")])

        native.inbound.extend(b"\xc0\x08\x46\xc0")
        self.assertEqual(driver.read(), b"\xc0\x08\x46\xc0")
        self.assertEqual(driver.writeSync(b"\xc0\x01\xc0"), 3)
        self.assertEqual(native.writes, [b"\xc0\x01\xc0"])

        driver.notifyOnlineStatusChanged(True, "RNode Radio")
        driver.notifyOnlineStatusChanged(False, "RNode Radio")
        self.assertEqual(native.online_values, [1, 0])

        native.state = 0
        self.assertEqual(driver.read(), b"")
        self.assertEqual(driver.read(), b"")
        self.assertEqual(transitions[-1], (False, "RNode 1234"))
        self.assertEqual(len(transitions), 2, "disconnect callback must fire exactly once")

    def test_timeout_disconnects_to_invalidate_late_corebluetooth_result(self):
        native = FakeNativeLibrary()
        native.connect = lambda _name: 0
        native.columba_rnode_connect.implementation = native.connect
        module = load_driver(native)
        driver = module.IOSRNodeDriver()
        driver.CONNECT_TIMEOUT = 0

        self.assertFalse(driver.connect("RNode 1234", "ble"))
        self.assertEqual(native.disconnect_count, 1)
        self.assertIsNone(driver.getConnectedDeviceName())

    def test_non_ble_mode_never_enters_native_transport(self):
        native = FakeNativeLibrary()
        module = load_driver(native)
        driver = module.IOSRNodeDriver()
        self.assertFalse(driver.connect("RNode 1234", "classic"))
        self.assertEqual(native.state, 0)


if __name__ == "__main__":
    unittest.main()
