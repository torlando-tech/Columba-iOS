#!/usr/bin/env python3
"""Static contract: iOS RNode stale-bond recovery wiring (Android PR #1100 parity).

The shipping Python-runtime RNode interface cannot be imported on a Linux CI box
(RNS is not installed), so the stale-bond recovery wiring is verified by source
inspection: the Swift transport must classify the CoreBluetooth stale-bond error
and expose a machine-readable failure code, the driver must surface it to Python,
and the interface must stop auto-reconnecting and expose the reason to the UI.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
NATIVE_BRIDGE = ROOT / "Sources/PythonBridge/PythonRNodeBLEBridge.swift"
PY_DRIVER = ROOT / "app/rnode/IOSRNodeDriver.py"
PY_INTERFACE = ROOT / "app/rnode/IOSRNodeInterface.py"
PY_BRIDGE = ROOT / "app/rns_bridge.py"
RNS_BACKEND = ROOT / "Sources/RNSAPI/Protocols/RnsBackend.swift"
VM = ROOT / "Sources/ColumbaApp/ViewModels/InterfaceManagementViewModel.swift"
SCREEN = ROOT / "Sources/ColumbaApp/Views/Settings/InterfaceManagementScreen.swift"


class IOSRNodeStaleBondContractTests(unittest.TestCase):
    def test_swift_transport_classifies_stale_bond_and_exposes_failure_code(self) -> None:
        bridge = NATIVE_BRIDGE.read_text()
        # Typed failure classification.
        self.assertIn("enum PythonRNodeFailureCode", bridge)
        self.assertIn("case pairingRequired", bridge)
        # CoreBluetooth ground truth: stale bond is CBErrorDomain code 14.
        self.assertIn("CBErrorDomain", bridge)
        self.assertIn("CBATTErrorDomain", bridge)
        # The reason is handed to Python across the C boundary.
        self.assertIn("columba_rnode_session_failure", bridge)
        self.assertIn("func failureCode(handle: Int32)", bridge)

    def test_driver_binds_failure_symbol_and_exposes_reason(self) -> None:
        driver = PY_DRIVER.read_text()
        self.assertIn("columba_rnode_session_failure", driver)
        self.assertIn("def getLastConnectionFailure(self):", driver)
        self.assertIn("pairing_required", driver)
        # The code must be captured while the session handle is still open.
        self.assertIn("def _capture_failure(self):", driver)

    def test_interface_stops_reconnect_and_exposes_status_reason(self) -> None:
        interface = PY_INTERFACE.read_text()
        self.assertIn("self.status_reason = None", interface)
        # start() consumes the failure reason the driver captured.
        self.assertIn("getLastConnectionFailure()", interface)
        # The reconnect loop halts on a stale bond instead of blind-retrying.
        self.assertIn('self.status_reason == "pairing_required"', interface)
        self.assertIn("stopping automatic reconnect", interface)

    def test_status_reason_is_surfaced_through_snapshot_to_ui(self) -> None:
        rns_bridge = PY_BRIDGE.read_text()
        self.assertIn('"status_reason": getattr(iface, "status_reason", None)', rns_bridge)
        backend = RNS_BACKEND.read_text()
        self.assertIn("case statusReason = \"status_reason\"", backend)
        self.assertIn("public let statusReason: String?", backend)
        vm = VM.read_text()
        self.assertIn("interfaceStatusReasons", vm)
        self.assertIn("func getStatusReason(for", vm)
        screen = SCREEN.read_text()
        self.assertIn("statusReason", screen)
        self.assertIn("pairingRequiredCard", screen)
        self.assertIn('statusReason == "pairing_required"', screen)


if __name__ == "__main__":
    unittest.main()
