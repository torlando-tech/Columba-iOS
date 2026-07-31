"""Native iOS BLE transport adapter for ``IOSRNodeInterface``.

The Reticulum interface owns KISS/RNode framing in Python. This adapter only
moves one raw Nordic UART Service byte stream across the Python/Swift boundary.
Every driver instance owns a native session handle, allowing distinct physical
RNodes to operate concurrently without sharing buffers or lifecycle state.
"""

from __future__ import annotations

import ctypes
import threading
import time


_STATE_DISCONNECTED = 0
_STATE_CONNECTING = 1
_STATE_CONNECTED = 2
_STATE_FAILED = 3
_INVALID_SESSION = 0


_lib = ctypes.CDLL(None)


def _required(name, argtypes, restype):
    try:
        fn = getattr(_lib, name)
    except AttributeError as exc:
        raise RuntimeError(f"IOSRNodeDriver: required native symbol {name} is missing") from exc
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


_open = _required(
    "columba_rnode_session_open",
    [ctypes.c_char_p, ctypes.c_char_p],
    ctypes.c_int32,
)
_close = _required("columba_rnode_session_close", [ctypes.c_int32], ctypes.c_int32)
_state = _required("columba_rnode_session_state", [ctypes.c_int32], ctypes.c_int32)
_read = _required(
    "columba_rnode_session_read",
    [ctypes.c_int32, ctypes.POINTER(ctypes.c_uint8), ctypes.c_int32],
    ctypes.c_int32,
)
_write = _required(
    "columba_rnode_session_write",
    [ctypes.c_int32, ctypes.POINTER(ctypes.c_uint8), ctypes.c_int32],
    ctypes.c_int32,
)
_set_online = _required(
    "columba_rnode_session_set_online",
    [ctypes.c_int32, ctypes.c_int32],
    ctypes.c_int32,
)


class IOSRNodeDriver:
    """Android ``KotlinRNodeBridge``-compatible facade over native Swift BLE."""

    CONNECT_TIMEOUT = 25.0
    READ_CAPACITY = 4096

    def __init__(self):
        self._device_name = None
        self._device_identifier = None
        self._session_handle = _INVALID_SESSION
        self._state_callback = None
        self._state_lock = threading.Lock()
        self._last_connected = False

    def _poll_state_transition(self):
        handle = self._session_handle
        state = int(_state(handle)) if handle > _INVALID_SESSION else _STATE_DISCONNECTED
        connected = state == _STATE_CONNECTED
        callback = None
        with self._state_lock:
            if connected != self._last_connected:
                self._last_connected = connected
                callback = self._state_callback
        if callback is not None:
            callback(connected, self._device_name)
        return state

    def connect(self, device_name, connection_mode="ble", device_identifier=None):
        if connection_mode != "ble" or not device_name:
            return False

        requested_name = str(device_name)
        requested_identifier = str(device_identifier) if device_identifier else None
        if self._session_handle > _INVALID_SESSION:
            if (
                self._device_name == requested_name
                and self._device_identifier == requested_identifier
                and self._poll_state_transition() == _STATE_CONNECTED
            ):
                return True
            self.disconnect()

        identifier_bytes = requested_identifier.encode("utf-8") if requested_identifier else None
        handle = int(_open(requested_name.encode("utf-8"), identifier_bytes))
        if handle <= _INVALID_SESSION:
            return False

        self._session_handle = handle
        self._device_name = requested_name
        self._device_identifier = requested_identifier
        deadline = time.monotonic() + self.CONNECT_TIMEOUT
        while time.monotonic() < deadline:
            state = self._poll_state_transition()
            if state == _STATE_CONNECTED:
                return True
            if state == _STATE_FAILED:
                self.disconnect()
                return False
            time.sleep(0.05)
        # Close only this timed-out session, invalidating any late callbacks while
        # leaving other physical RNode sessions untouched.
        self.disconnect()
        return False

    def disconnect(self):
        handle = self._session_handle
        self._session_handle = _INVALID_SESSION
        if handle > _INVALID_SESSION:
            _close(handle)
        self._poll_state_transition()
        self._device_name = None
        self._device_identifier = None

    def isConnected(self):
        return self._poll_state_transition() == _STATE_CONNECTED

    def getConnectedDeviceName(self):
        return self._device_name if self.isConnected() else None

    def read(self):
        # The interface read loop polls even when no bytes arrive, so this also
        # delivers later physical disconnects to the reconnection callback.
        self._poll_state_transition()
        handle = self._session_handle
        if handle <= _INVALID_SESSION:
            return b""
        buffer = (ctypes.c_uint8 * self.READ_CAPACITY)()
        count = int(_read(handle, buffer, self.READ_CAPACITY))
        if count <= 0:
            return b""
        return bytes(buffer[:count])

    def writeSync(self, data):
        payload = bytes(data)
        if not payload:
            return 0
        handle = self._session_handle
        if handle <= _INVALID_SESSION:
            return -1
        buffer = (ctypes.c_uint8 * len(payload)).from_buffer_copy(payload)
        return int(_write(handle, buffer, len(payload)))

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
        handle = self._session_handle
        if handle <= _INVALID_SESSION:
            return -1
        return int(_set_online(handle, 1 if online else 0))
