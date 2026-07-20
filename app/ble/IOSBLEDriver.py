"""IOSBLEDriver — Python side of the Reticulum BLE driver for iOS.

Mirrors `AndroidBLEDriver.py`:
  - Implements upstream `BLEDriverInterface` (14 methods + property pair).
  - Routes outbound operations (start/stop/scan/advertise/connect/send) to
    the Swift `SwiftBLEBridge` via ctypes-bound C-ABI shims compiled into
    the app binary (exported by `Sources/SwiftBLEBridge/BleNativeBindings.swift`).
  - Receives inbound events (`on_device_discovered` etc.) from Swift via the
    Swift→Python callback registry in `rns_bridge` — Swift calls
    `PythonBridge.invokeBLECallback(slot=..., args=...)` which looks up the
    Python callable stored under that slot name.
  - Tracks per-peer identity ↔ address reunification so the upstream
    BLEInterface sees cross-platform MAC rotation as `on_address_changed`
    events rather than as new connections.
  - Synchronous `on_duplicate_identity_detected(addr, identity_bytes) -> bool`
    is registered like the other callbacks; Swift uses
    `invokeBLECallbackBoolSync` to fetch the result.
"""

from __future__ import annotations

import ctypes
import threading
from typing import Any, Callable, List, Optional

import RNS
from ble_reticulum.bluetooth_driver import BLEDriverInterface, BLEDevice, DriverState

# rns_bridge module hosts the BLE callback registry + bridge-handle slot.
# Imported once at module load; `set_ble_callback` etc. resolve through it.
import rns_bridge as _bridge_module


# ────────────────────────────────────────────────────────────────────
# ctypes binding to SwiftBLEBridge's C-ABI shims
# (Sources/SwiftBLEBridge/BleNativeBindings.swift)
# ────────────────────────────────────────────────────────────────────
#
# All shims live in the running process's symbol table; CDLL(None) opens
# the current binary. Return values: 0 on success, negative errno-like on
# failure.

try:
    _lib = ctypes.CDLL(None)
except OSError as e:
    raise RuntimeError(f"IOSBLEDriver: failed to dlopen current process: {e}")


def _decl(name: str, argtypes: list, restype: Any) -> Optional[Callable]:
    """Look up a symbol in the process binary and assign ctypes signatures.
    Returns None if the symbol isn't present (so the driver can degrade
    gracefully on platforms where the Swift bridge isn't loaded — e.g.,
    unit-test harnesses that import this module without a running app)."""
    try:
        fn = getattr(_lib, name)
    except AttributeError:
        return None
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


# C-ABI surface — exported from Swift via @_cdecl.
_columba_ble_start = _decl(
    "columba_ble_start",
    [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p],
    ctypes.c_int32,
)
_columba_ble_stop = _decl("columba_ble_stop", [], ctypes.c_int32)
_columba_ble_set_identity = _decl(
    "columba_ble_set_identity", [ctypes.c_char_p, ctypes.c_int32], ctypes.c_int32
)
_columba_ble_sync_existing_connections = _decl(
    "columba_ble_sync_existing_connections", [], ctypes.c_int32
)
_columba_ble_request_identity_resync = _decl(
    "columba_ble_request_identity_resync", [ctypes.c_char_p], ctypes.c_int32
)
_columba_ble_start_scanning = _decl("columba_ble_start_scanning", [], ctypes.c_int32)
_columba_ble_stop_scanning = _decl("columba_ble_stop_scanning", [], ctypes.c_int32)
_columba_ble_start_advertising = _decl(
    "columba_ble_start_advertising",
    [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int32],
    ctypes.c_int32,
)
_columba_ble_stop_advertising = _decl("columba_ble_stop_advertising", [], ctypes.c_int32)
_columba_ble_connect = _decl("columba_ble_connect", [ctypes.c_char_p], ctypes.c_int32)
_columba_ble_disconnect = _decl("columba_ble_disconnect", [ctypes.c_char_p], ctypes.c_int32)
_columba_ble_send = _decl(
    "columba_ble_send",
    [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int32],
    ctypes.c_int32,
)
_columba_ble_get_peer_role = _decl(
    "columba_ble_get_peer_role", [ctypes.c_char_p], ctypes.c_int32
)
_columba_ble_get_peer_mtu = _decl(
    "columba_ble_get_peer_mtu", [ctypes.c_char_p], ctypes.c_int32
)
_columba_ble_configure_power = _decl(
    "columba_ble_configure_power", [ctypes.c_char_p], ctypes.c_int32
)


# Callback slot names — must match BleCallbackSlot.rawValue in Swift.
_SLOT_DISCOVERED = "on_device_discovered"
_SLOT_CONNECTED = "on_device_connected"
_SLOT_DISCONNECTED = "on_device_disconnected"
_SLOT_DATA = "on_data_received"
_SLOT_MTU = "on_mtu_negotiated"
_SLOT_IDENTITY = "on_identity_received"
_SLOT_ADDRESS_CHANGED = "on_address_changed"
_SLOT_DUPLICATE = "on_duplicate_identity_detected"
_SLOT_ERROR = "on_error"


class IOSBLEDriver(BLEDriverInterface):
    """iOS implementation of BLEDriverInterface."""

    def __init__(self, **kwargs: Any) -> None:
        # Upstream BLEInterface passes 6 kwargs (discovery_interval,
        # connection_timeout, min_rssi, service_discovery_delay, max_peers,
        # adapter_index). iOS doesn't need any of them — CoreBluetooth
        # auto-manages scan/connect lifecycles, and adapter_index is
        # meaningless without dbus. Capture for debugging only.
        super().__init__()
        self._init_kwargs = kwargs
        self._state: DriverState = DriverState.IDLE
        self._connected_peers: list[str] = []
        # address (str) → identity hash (32-char hex). Updated by the
        # `on_identity_received` callback once the peer's identity is
        # known. Consulted to detect MAC rotation (same identity at new
        # address) and to surface `on_address_changed` to BLEInterface.
        self._address_to_identity: dict[str, str] = {}
        self._identity_to_address: dict[str, str] = {}
        self._lock = threading.Lock()
        # Power preset captured in `set_power_mode` — passed to Swift via
        # `configure_power` so the Settings/DiagLog status output reflects
        # it. iOS auto-manages duty cycle so this is informational.
        self._power_preset: str = "balanced"
        self._register_callbacks()
        # CoreBluetooth can restore links before embedded Python restarts.
        # Replay them only after every Python callback slot is registered.
        if _columba_ble_sync_existing_connections is not None:
            _columba_ble_sync_existing_connections()

    # ------------------------------------------------------------------
    # Callback registration — raw-arg handlers lift Swift's primitive
    # args into the BLEDevice / bytes objects upstream expects.
    # ------------------------------------------------------------------

    def _register_callbacks(self) -> None:
        _bridge_module.set_ble_callback(_SLOT_DISCOVERED, self._raw_on_device_discovered)
        _bridge_module.set_ble_callback(_SLOT_CONNECTED, self._raw_on_device_connected)
        _bridge_module.set_ble_callback(_SLOT_DISCONNECTED, self._raw_on_device_disconnected)
        _bridge_module.set_ble_callback(_SLOT_DATA, self._raw_on_data_received)
        _bridge_module.set_ble_callback(_SLOT_MTU, self._raw_on_mtu_negotiated)
        _bridge_module.set_ble_callback(_SLOT_IDENTITY, self._raw_on_identity_received)
        _bridge_module.set_ble_callback(_SLOT_ADDRESS_CHANGED, self._raw_on_address_changed)
        _bridge_module.set_ble_callback(_SLOT_DUPLICATE, self._raw_on_duplicate_identity_detected)
        _bridge_module.set_ble_callback(_SLOT_ERROR, self._raw_on_error)

    def _raw_on_device_discovered(
        self, address: str, name: str, rssi: int, service_uuids: list
    ) -> None:
        if self.on_device_discovered is None:
            return
        device = BLEDevice(
            address=address,
            name=name or "",
            rssi=int(rssi),
            service_uuids=list(service_uuids or []),
        )
        try:
            self.on_device_discovered(device)
        except Exception as e:
            RNS.log(f"IOSBLEDriver: on_device_discovered raised: {e}", RNS.LOG_ERROR)

    def _raw_on_device_connected(
        self, address: str, identity_bytes_or_none: Optional[bytes]
    ) -> None:
        if self.on_device_connected is None:
            return
        identity = identity_bytes_or_none if isinstance(identity_bytes_or_none, (bytes, bytearray)) else None
        if identity is not None:
            with self._lock:
                self._address_to_identity[address] = bytes(identity).hex()
                self._identity_to_address[bytes(identity).hex()] = address
            if address not in self._connected_peers:
                self._connected_peers.append(address)
        try:
            self.on_device_connected(address, identity)
        except Exception as e:
            RNS.log(f"IOSBLEDriver: on_device_connected raised: {e}", RNS.LOG_ERROR)

    def _raw_on_device_disconnected(self, address: str) -> None:
        with self._lock:
            ident = self._address_to_identity.pop(address, None)
            if ident:
                # Only drop the reverse mapping if it still points at this
                # address — same-identity-different-address peers (MAC
                # rotation) would otherwise lose their forward map.
                if self._identity_to_address.get(ident) == address:
                    self._identity_to_address.pop(ident, None)
            if address in self._connected_peers:
                self._connected_peers.remove(address)
        if self.on_device_disconnected is not None:
            try:
                self.on_device_disconnected(address)
            except Exception as e:
                RNS.log(f"IOSBLEDriver: on_device_disconnected raised: {e}", RNS.LOG_ERROR)

    def _raw_on_data_received(self, address: str, data: bytes) -> None:
        if self.on_data_received is None:
            return
        try:
            self.on_data_received(address, bytes(data))
        except Exception as e:
            RNS.log(f"IOSBLEDriver: on_data_received raised: {e}", RNS.LOG_ERROR)

    def _raw_on_mtu_negotiated(self, address: str, mtu: int) -> None:
        if self.on_mtu_negotiated is None:
            return
        try:
            self.on_mtu_negotiated(address, int(mtu))
        except Exception as e:
            RNS.log(f"IOSBLEDriver: on_mtu_negotiated raised: {e}", RNS.LOG_ERROR)

    def _raw_on_identity_received(self, address: str, identity_hex: str) -> None:
        """Swift surfaces identity as a 32-char hex string. Update the
        reunification maps; upstream interface uses these to detect
        cross-platform MAC rotation."""
        try:
            identity_bytes = bytes.fromhex(identity_hex)
        except ValueError:
            RNS.log(f"IOSBLEDriver: bad identity_hex={identity_hex!r}", RNS.LOG_ERROR)
            return
        with self._lock:
            self._address_to_identity[address] = identity_hex
            self._identity_to_address[identity_hex] = address
        # Match Android's adapter contract: identity-before-connected only fills
        # the cache. A late identity or explicit resync for an already-connected
        # native peer must notify upstream so it can rebuild its mapping.
        with self._lock:
            already_connected = address in self._connected_peers
        if already_connected and self.on_device_connected is not None:
            try:
                self.on_device_connected(address, identity_bytes)
            except Exception as e:
                RNS.log(f"IOSBLEDriver: on_device_connected (post-identity) raised: {e}", RNS.LOG_ERROR)

    def _raw_on_address_changed(
        self, old_address: str, new_address: str, identity_hash_hex: str
    ) -> None:
        with self._lock:
            self._address_to_identity.pop(old_address, None)
            self._address_to_identity[new_address] = identity_hash_hex
            self._identity_to_address[identity_hash_hex] = new_address
            if old_address in self._connected_peers:
                self._connected_peers.remove(old_address)
            if new_address not in self._connected_peers:
                self._connected_peers.append(new_address)
        if self.on_address_changed is not None:
            try:
                self.on_address_changed(old_address, new_address, identity_hash_hex)
            except Exception as e:
                RNS.log(f"IOSBLEDriver: on_address_changed raised: {e}", RNS.LOG_ERROR)

    def _raw_on_duplicate_identity_detected(
        self, address: str, identity_hex: str
    ) -> bool:
        """Synchronous bool-return — Swift blocks on this before accepting a
        connection."""
        try:
            identity_bytes = bytes.fromhex(identity_hex)
        except ValueError:
            return False
        cb = getattr(self, "on_duplicate_identity_detected", None)
        if cb is None:
            return False
        try:
            return bool(cb(address, identity_bytes))
        except Exception as e:
            RNS.log(f"IOSBLEDriver: on_duplicate_identity_detected raised: {e}", RNS.LOG_ERROR)
            return False

    def _raw_on_error(self, severity: str, message: str) -> None:
        if self.on_error is None:
            return
        try:
            self.on_error(severity, message, None)
        except Exception as e:
            RNS.log(f"IOSBLEDriver: on_error raised: {e}", RNS.LOG_ERROR)

    # ------------------------------------------------------------------
    # BLEDriverInterface: lifecycle
    # ------------------------------------------------------------------

    def start(
        self,
        service_uuid: str,
        rx_char_uuid: str,
        tx_char_uuid: str,
        identity_char_uuid: str,
    ) -> None:
        if _columba_ble_start is None:
            raise RuntimeError("columba_ble_start symbol not found — Swift bridge missing?")
        rc = _columba_ble_start(
            service_uuid.encode("utf-8"),
            rx_char_uuid.encode("utf-8"),
            tx_char_uuid.encode("utf-8"),
            identity_char_uuid.encode("utf-8"),
        )
        if rc != 0:
            raise RuntimeError(f"columba_ble_start failed: rc={rc}")

    def stop(self) -> None:
        if _columba_ble_stop is None:
            return
        rc = _columba_ble_stop()
        if rc != 0:
            RNS.log(f"columba_ble_stop returned rc={rc}", RNS.LOG_WARNING)
        self._state = DriverState.IDLE
        with self._lock:
            self._address_to_identity.clear()
            self._identity_to_address.clear()
            self._connected_peers.clear()

    def set_identity(self, identity_bytes: bytes) -> None:
        if _columba_ble_set_identity is None:
            raise RuntimeError("columba_ble_set_identity symbol not found")
        data = bytes(identity_bytes)
        if len(data) != 16:
            raise ValueError(f"BLE transport identity must be 16 bytes, got {len(data)}")
        rc = _columba_ble_set_identity(data, len(data))
        if rc != 0:
            raise RuntimeError(f"columba_ble_set_identity failed: rc={rc}")

    # ------------------------------------------------------------------
    # BLEDriverInterface: state
    # ------------------------------------------------------------------

    @property
    def state(self) -> DriverState:
        return self._state

    @property
    def connected_peers(self) -> List[str]:
        with self._lock:
            return list(self._connected_peers)

    # ------------------------------------------------------------------
    # BLEDriverInterface: scan + advertise
    # ------------------------------------------------------------------

    def start_scanning(self) -> None:
        if _columba_ble_start_scanning is None:
            raise RuntimeError("columba_ble_start_scanning symbol not found")
        rc = _columba_ble_start_scanning()
        if rc != 0:
            raise RuntimeError(f"columba_ble_start_scanning failed: rc={rc}")
        self._state = DriverState.SCANNING

    def stop_scanning(self) -> None:
        if _columba_ble_stop_scanning is None:
            return
        _columba_ble_stop_scanning()
        if self._state == DriverState.SCANNING:
            self._state = DriverState.IDLE

    def start_advertising(
        self, device_name: Optional[str], identity: bytes
    ) -> None:
        if _columba_ble_start_advertising is None:
            raise RuntimeError("columba_ble_start_advertising symbol not found")
        name_bytes = (device_name or "").encode("utf-8")
        identity_bytes = bytes(identity)
        rc = _columba_ble_start_advertising(name_bytes, identity_bytes, len(identity_bytes))
        if rc != 0:
            raise RuntimeError(f"columba_ble_start_advertising failed: rc={rc}")
        self._state = DriverState.ADVERTISING

    def stop_advertising(self) -> None:
        if _columba_ble_stop_advertising is None:
            return
        _columba_ble_stop_advertising()
        if self._state == DriverState.ADVERTISING:
            self._state = DriverState.IDLE

    # ------------------------------------------------------------------
    # BLEDriverInterface: connect + send
    # ------------------------------------------------------------------

    def connect(self, address: str) -> None:
        if _columba_ble_connect is None:
            raise RuntimeError("columba_ble_connect symbol not found")
        rc = _columba_ble_connect(address.encode("utf-8"))
        if rc != 0:
            RNS.log(f"columba_ble_connect failed for {address}: rc={rc}", RNS.LOG_WARNING)

    def disconnect(self, address: str) -> None:
        if _columba_ble_disconnect is None:
            return
        _columba_ble_disconnect(address.encode("utf-8"))

    def send(self, address: str, data: bytes) -> None:
        if _columba_ble_send is None:
            raise RuntimeError("columba_ble_send symbol not found")
        payload = bytes(data)
        rc = _columba_ble_send(address.encode("utf-8"), payload, len(payload))
        if rc != 0:
            raise RuntimeError(f"columba_ble_send rejected frame: rc={rc}")

    # ------------------------------------------------------------------
    # BLEDriverInterface: GATT char ops
    # ------------------------------------------------------------------
    # Upstream BLEInterface uses these only for the Identity characteristic
    # read (during the connection handshake). The Swift bridge bakes those
    # ops into the connect path automatically and surfaces the result via
    # on_identity_received, so the driver never explicitly calls
    # read_characteristic. We keep the methods present (the abstract base
    # class requires them) but raise NotImplementedError on misuse.

    def read_characteristic(self, address: str, char_uuid: str) -> bytes:
        raise NotImplementedError(
            "IOSBLEDriver.read_characteristic — identity read is automatic via Swift bridge"
        )

    def write_characteristic(self, address: str, char_uuid: str, data: bytes) -> None:
        raise NotImplementedError(
            "IOSBLEDriver.write_characteristic — handshake write is automatic via Swift bridge"
        )

    def start_notify(
        self,
        address: str,
        char_uuid: str,
        callback: Callable[[bytes], None],
    ) -> None:
        raise NotImplementedError(
            "IOSBLEDriver.start_notify — CCCD enable is automatic via Swift bridge"
        )

    # ------------------------------------------------------------------
    # BLEDriverInterface: config + queries
    # ------------------------------------------------------------------

    def get_local_address(self) -> str:
        # iOS hides the local Bluetooth MAC. The sentinel mirrors what
        # Android does — upstream BLEInterface's MAC-sort dedup
        # optimization isn't reliable across platforms anyway (per the
        # plan's Q6 decision), so we accept the wasted-connection cost
        # and let the synchronous on_duplicate_identity_detected check
        # resolve races post-connect.
        return "00:00:00:00:00:00"

    def get_peer_role(self, address: str) -> Optional[str]:
        if _columba_ble_get_peer_role is None:
            return None
        role = int(_columba_ble_get_peer_role(address.encode("utf-8")))
        if role == 1:
            return "central"
        if role == 2:
            return "peripheral"
        return None

    def get_peer_mtu(self, address: str) -> Optional[int]:
        if _columba_ble_get_peer_mtu is None:
            return None
        mtu = int(_columba_ble_get_peer_mtu(address.encode("utf-8")))
        return mtu if mtu > 0 else None

    def request_identity_resync(self, address: str) -> bool:
        if _columba_ble_request_identity_resync is None:
            return False
        return _columba_ble_request_identity_resync(address.encode("utf-8")) == 0

    def set_service_discovery_delay(self, seconds: float) -> None:
        # No-op on iOS: CoreBluetooth doesn't need bluezero's D-Bus
        # registration delay workaround.
        return None

    def set_power_mode(self, mode: str) -> None:
        self._power_preset = mode
        if _columba_ble_configure_power is None:
            return
        _columba_ble_configure_power(mode.encode("utf-8"))
