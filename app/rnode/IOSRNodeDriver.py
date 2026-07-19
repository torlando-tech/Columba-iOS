"""Native iOS BLE transport adapter for ``IOSRNodeInterface``.

The Reticulum interface owns KISS/RNode framing in Python. This adapter only
moves the raw Nordic UART Service byte stream across the Python/Swift boundary
through C-ABI functions exported by ``PythonRNodeBLEBridge.swift``.
"""

from __future__ import annotations

import ctypes
import threading
import time


_STATE_DISCONNECTED = 0
_STATE_CONNECTING = 1
_STATE_CONNECTED = 2
_STATE_FAILED = 3


_lib = ctypes.CDLL(None)


def _required(name, argtypes, restype):
    try:
        fn = getattr(_lib, name)
    except AttributeError as exc:
        raise RuntimeError(f"IOSRNodeDriver: required native symbol {name} is missing") from exc
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


_connect = _required("columba_rnode_connect", [ctypes.c_char_p], ctypes.c_int32)
_disconnect = _required("columba_rnode_disconnect", [], ctypes.c_int32)
_state = _required("columba_rnode_state", [], ctypes.c_int32)
_read = _required(
    "columba_rnode_read", [ctypes.POINTER(ctypes.c_uint8), ctypes.c_int32], ctypes.c_int32
)
_write = _required(
    "columba_rnode_write", [ctypes.POINTER(ctypes.c_uint8), ctypes.c_int32], ctypes.c_int32
)
_set_online = _required("columba_rnode_set_online", [ctypes.c_int32], ctypes.c_int32)


class IOSRNodeDriver:
    """Android ``KotlinRNodeBridge``-compatible facade over native Swift BLE."""

    CONNECT_TIMEOUT = 25.0
    READ_CAPACITY = 4096

    def __init__(self):
        self._device_name = None
        self._state_callback = None
        self._state_lock = threading.Lock()
        self._last_connected = False

    def _poll_state_transition(self):
        state = int(_state())
        connected = state == _STATE_CONNECTED
        callback = None
        with self._state_lock:
            if connected != self._last_connected:
                self._last_connected = connected
                callback = self._state_callback
        if callback is not None:
            callback(connected, self._device_name)
        return state

    def connect(self, device_name, connection_mode="ble"):
        if connection_mode != "ble" or not device_name:
            return False
        rc = _connect(str(device_name).encode("utf-8"))
        if rc != 0:
            return False
        self._device_name = str(device_name)
        deadline = time.monotonic() + self.CONNECT_TIMEOUT
        while time.monotonic() < deadline:
            state = self._poll_state_transition()
            if state == _STATE_CONNECTED:
                return True
            if state == _STATE_FAILED:
                self.disconnect()
                return False
            time.sleep(0.05)
        # Invalidate a late CoreBluetooth result from this timed-out attempt.
        self.disconnect()
        return False

    def disconnect(self):
        _disconnect()
        self._poll_state_transition()
        self._device_name = None

    def isConnected(self):
        return self._poll_state_transition() == _STATE_CONNECTED

    def getConnectedDeviceName(self):
        return self._device_name if self.isConnected() else None

    def read(self):
        # The interface read loop polls even when no bytes arrive, so this also
        # delivers later physical disconnects to the reconnection callback.
        self._poll_state_transition()
        buffer = (ctypes.c_uint8 * self.READ_CAPACITY)()
        count = int(_read(buffer, self.READ_CAPACITY))
        if count <= 0:
            return b""
        return bytes(buffer[:count])

    def writeSync(self, data):
        payload = bytes(data)
        if not payload:
            return 0
        buffer = (ctypes.c_uint8 * len(payload)).from_buffer_copy(payload)
        return int(_write(buffer, len(payload)))

    def write(self, data):
        return self.writeSync(data)

    def setOnDataReceived(self, _callback):
        return None

    def setOnConnectionStateChanged(self, callback):
        with self._state_lock:
            self._state_callback = callback
            connected = self._last_connected
        if callback is not None:
            callback(connected, self._device_name)

    def notifyOnlineStatusChanged(self, online, _interface_name=None):
        _set_online(1 if online else 0)
