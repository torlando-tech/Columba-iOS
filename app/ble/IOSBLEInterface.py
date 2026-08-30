"""IOSBLEInterface — Reticulum custom interface for iOS BLE mesh.

Mirrors Android's `AndroidBLEInterface.py`. Reticulum loads this file at config
parse time when an interface section has `type = IOSBLEInterface`:

  [interfaces]
    [[ble0]]
      enabled = yes
      type = IOSBLEInterface

The file is copied from `<bundle>/app/ble/IOSBLEInterface.py` to
`<configDir>/interfaces/IOSBLEInterface.py` at app startup by
`AppServices.startBLEInterface()`. The sibling `IOSBLEDriver.py` is also
copied; this file adds `interfacepath` to sys.path so the driver is
importable.

The `interface_class` module attribute is what Reticulum's external-interface
loader extracts after exec()'ing this file (see RNS.Reticulum:1017).
"""

import RNS
import sys
import os

# Reticulum exec()'s this file with `Interface` and `RNS` injected as globals.
# To import sibling modules from the same interfaces dir, prepend it to
# sys.path. The path is configdir/interfaces, which Reticulum has already
# created by this point (see RNS.Reticulum:317).
_this_file = globals().get("__file__")
if _this_file:
    _interfaces_dir = os.path.dirname(os.path.abspath(_this_file))
else:
    # Fallback: ask Reticulum where it just loaded us from.
    _interfaces_dir = RNS.Reticulum.interfacepath
if _interfaces_dir and _interfaces_dir not in sys.path:
    sys.path.insert(0, _interfaces_dir)

# ble_reticulum is installed via pip into app_packages/ at build time and
# already on sys.path via PythonRuntime's site.addsitedir() call.
from ble_reticulum.BLEInterface import BLEInterface

# Sibling driver. Lives next to this file in <configDir>/interfaces/.
from IOSBLEDriver import IOSBLEDriver


class IOSBLEInterface(BLEInterface):
    """iOS-flavored BLE interface. All peer management, fragmentation,
    reassembly, MAC-rotation grace, and identity handshaking is inherited
    from upstream `BLEInterface`. We just pin the platform driver and apply
    iOS-specific power knobs."""

    # Override driver class so the parent constructor picks the right impl.
    driver_class = IOSBLEDriver

    def __init__(self, owner, config=None):
        super().__init__(owner, config)

        # Upstream disables peripheral mode when its Linux/BlueZ
        # BLEGATTServer import is unavailable. That capability probe does not
        # apply on iOS: IOSBLEDriver delegates the GATT server to
        # SwiftBLEBridge/CoreBluetooth. Restore the operator's configured
        # setting before final_init() decides whether to start advertising.
        enable_peripheral = True if config is None else config.get("enable_peripheral", True)
        if isinstance(enable_peripheral, str):
            enable_peripheral = enable_peripheral.lower() in ("yes", "true", "1")
        self.enable_peripheral = bool(enable_peripheral)

        # Power preset — informational on iOS (the OS auto-manages duty
        # cycle). Forwarded to the Swift bridge so it can mirror Android's
        # `configurePower` parity output in DiagLog.
        if config and hasattr(self, "driver") and self.driver is not None:
            preset = config.get("ble_power_preset", "balanced")
            try:
                self.driver.set_power_mode(preset)
            except Exception as e:
                RNS.log(f"IOSBLEInterface: set_power_mode failed: {e}", RNS.LOG_WARNING)

        RNS.log(f"iOS BLE Interface '{self.name}' initialized", RNS.LOG_INFO)

    def get_rssi(self):
        """Get the RSSI of the most recently received message, in dBm.

        Called at message-delivery time by the Python bridge's
        `_signal_metrics` to extract a signal-strength metric for the
        receiving-interface card. Mirrors Android's
        `AndroidBLEInterface.get_rssi()` -> `driver.get_last_receive_rssi()`.

        Returns:
            RSSI in dBm (negative int), or None when unavailable.

        Note:
            iOS BLE does not provide per-packet RSSI like RNode hardware.
            This returns the last known connection RSSI from the Swift
            bridge, which is updated from `readRSSI()` polling on the
            established central-side link (falling back to the last
            scan-time discovery report). Returns None for peripheral-role
            peers, for which Core Bluetooth exposes no RSSI — the
            "dependent on BLE role" behavior called out in the issue.
        """
        driver = getattr(self, "driver", None)
        if driver is None:
            return None
        return driver.get_last_receive_rssi()


# Required by Reticulum's external-interface loader.
interface_class = IOSBLEInterface
