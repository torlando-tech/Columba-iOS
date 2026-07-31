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
        self.next_handle = 1
        self.sessions = {}
        self.claims = {}
        self.closed_handles = []
        self.columba_rnode_session_open = FakeFunction(self.open)
        self.columba_rnode_session_close = FakeFunction(self.close)
        self.columba_rnode_session_state = FakeFunction(self.state)
        self.columba_rnode_session_read = FakeFunction(self.read)
        self.columba_rnode_session_write = FakeFunction(self.write)
        self.columba_rnode_session_set_online = FakeFunction(self.set_online)

    @staticmethod
    def _text(value):
        return value.decode("utf-8") if value else None

    def open(self, name, identifier):
        name = self._text(name) or ""
        identifier = self._text(identifier)
        key = ("id", identifier.lower()) if identifier else ("name", name.lower())
        if key in self.claims:
            return -2
        handle = self.next_handle
        self.next_handle += 1
        self.claims[key] = handle
        self.sessions[handle] = {
            "key": key,
            "name": name,
            "state": 2,
            "inbound": bytearray(),
            "writes": [],
            "online": [],
        }
        return handle

    def close(self, handle):
        session = self.sessions.pop(int(handle), None)
        if session is None:
            return -1
        self.claims.pop(session["key"], None)
        self.closed_handles.append(int(handle))
        return 0

    def state(self, handle):
        session = self.sessions.get(int(handle))
        return session["state"] if session else 0

    def read(self, handle, output, capacity):
        session = self.sessions.get(int(handle))
        if session is None:
            return -1
        inbound = session["inbound"]
        count = min(int(capacity), len(inbound))
        for index in range(count):
            output[index] = inbound[index]
        del inbound[:count]
        return count

    def write(self, handle, data, count):
        session = self.sessions.get(int(handle))
        if session is None:
            return -1
        session["writes"].append(bytes(data[: int(count)]))
        return int(count)

    def set_online(self, handle, value):
        session = self.sessions.get(int(handle))
        if session is None:
            return -1
        session["online"].append(int(value))
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

        self.assertTrue(driver.connect("RNode 1234", "ble", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        handle = driver._session_handle
        transitions = []
        driver.setOnConnectionStateChanged(
            lambda connected, name: transitions.append((connected, name))
        )
        self.assertEqual(transitions, [(True, "RNode 1234")])

        native.sessions[handle]["inbound"].extend(b"\xc0\x08\x46\xc0")
        self.assertEqual(driver.read(), b"\xc0\x08\x46\xc0")
        self.assertEqual(driver.writeSync(b"\xc0\x01\xc0"), 3)
        self.assertEqual(native.sessions[handle]["writes"], [b"\xc0\x01\xc0"])

        driver.notifyOnlineStatusChanged(True, "RNode Radio")
        driver.notifyOnlineStatusChanged(False, "RNode Radio")
        self.assertEqual(native.sessions[handle]["online"], [1, 0])

        native.sessions[handle]["state"] = 0
        self.assertEqual(driver.read(), b"")
        self.assertEqual(driver.read(), b"")
        self.assertEqual(transitions[-1], (False, "RNode 1234"))
        self.assertEqual(len(transitions), 2, "disconnect callback must fire exactly once")

    def test_distinct_devices_have_independent_sessions_and_duplicate_is_rejected(self):
        native = FakeNativeLibrary()
        module = load_driver(native)
        first = module.IOSRNodeDriver()
        second = module.IOSRNodeDriver()
        duplicate = module.IOSRNodeDriver()

        self.assertTrue(first.connect("RNode", "ble", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        self.assertTrue(second.connect("RNode", "ble", "11111111-2222-3333-4444-555555555555"))
        self.assertNotEqual(first._session_handle, second._session_handle)
        self.assertFalse(duplicate.connect("Renamed RNode", "ble", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        self.assertEqual(first.writeSync(b"first"), 5)
        self.assertEqual(second.writeSync(b"second"), 6)
        self.assertEqual(native.sessions[first._session_handle]["writes"], [b"first"])
        self.assertEqual(native.sessions[second._session_handle]["writes"], [b"second"])

        first.disconnect()
        self.assertTrue(duplicate.connect("Renamed RNode", "ble", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        self.assertTrue(second.isConnected())

    def test_timeout_closes_only_its_session(self):
        native = FakeNativeLibrary()
        module = load_driver(native)
        driver = module.IOSRNodeDriver()
        driver.CONNECT_TIMEOUT = 0

        original_open = native.open
        def connecting_open(name, identifier):
            handle = original_open(name, identifier)
            native.sessions[handle]["state"] = 1
            return handle
        native.columba_rnode_session_open.implementation = connecting_open

        self.assertFalse(driver.connect("RNode 1234", "ble"))
        self.assertEqual(native.closed_handles, [1])
        self.assertIsNone(driver.getConnectedDeviceName())

    def test_non_ble_mode_never_enters_native_transport(self):
        native = FakeNativeLibrary()
        module = load_driver(native)
        driver = module.IOSRNodeDriver()
        self.assertFalse(driver.connect("RNode 1234", "classic"))
        self.assertEqual(native.sessions, {})


if __name__ == "__main__":
    unittest.main()
