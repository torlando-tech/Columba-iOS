#!/usr/bin/env python3
"""Shipping Python-runtime RNode native bridge contracts."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
CONFIG_WRITER = ROOT / "Sources/ColumbaApp/Services/PythonConfigWriter.swift"
NATIVE_BRIDGE = ROOT / "Sources/PythonBridge/PythonRNodeBLEBridge.swift"
PY_INTERFACE = ROOT / "app/rnode/IOSRNodeInterface.py"
PY_DRIVER = ROOT / "app/rnode/IOSRNodeDriver.py"
RECONCILER = ROOT / "support/isolate-modelb-targets.rb"


class PythonRNodeBridgeContractTests(unittest.TestCase):
    def test_python_interface_and_driver_ship_the_required_contract(self) -> None:
        interface = PY_INTERFACE.read_text()
        driver = PY_DRIVER.read_text()
        self.assertIn("class IOSRNodeInterface(Interface):", interface)
        self.assertIn("interface_class = IOSRNodeInterface", interface)
        self.assertIn("from IOSRNodeDriver import IOSRNodeDriver", interface)
        self.assertIn("class IOSRNodeDriver:", driver)
        for symbol in (
            "columba_rnode_session_open",
            "columba_rnode_session_close",
            "columba_rnode_session_state",
            "columba_rnode_session_read",
            "columba_rnode_session_write",
            "columba_rnode_session_set_online",
        ):
            self.assertIn(symbol, driver)
        self.assertIn("sys.path.insert(0, _interfaces_dir)", interface)
        self.assertIn("from IOSRNodeDriver import IOSRNodeDriver", interface)

    def test_config_enables_python_rnode_with_radio_parameters(self) -> None:
        source = CONFIG_WRITER.read_text()
        branch = re.search(
            r"case \.rnode\(let cfg\):(?P<body>.*?)case \.multipeer:",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(branch)
        assert branch is not None
        body = branch.group("body")
        for fragment in (
            'type = IOSRNodeInterface',
            'connection_mode = ble',
            'target_device_name',
            'target_device_identifier',
            'frequency',
            'bandwidth',
            'txpower',
            'spreadingfactor',
            'codingrate',
        ):
            self.assertIn(fragment, body)
        self.assertNotIn("Python path retired", source)
        self.assertNotRegex(source, r"case \.rnode, \.multipeer: isInertPlaceholder = true")

    def test_native_bridge_is_shipping_only_and_exports_complete_c_abi(self) -> None:
        native = NATIVE_BRIDGE.read_text()
        for declaration in (
            '@_cdecl("columba_rnode_session_open")',
            '@_cdecl("columba_rnode_session_close")',
            '@_cdecl("columba_rnode_session_state")',
            '@_cdecl("columba_rnode_session_read")',
            '@_cdecl("columba_rnode_session_write")',
            '@_cdecl("columba_rnode_session_set_online")',
            '@_cdecl("columba_rnode_connect")',
            '@_cdecl("columba_rnode_disconnect")',
            '@_cdecl("columba_rnode_state")',
            '@_cdecl("columba_rnode_read")',
            '@_cdecl("columba_rnode_write")',
            '@_cdecl("columba_rnode_set_online")',
        ):
            self.assertIn(declaration, native)
        self.assertIn("final class PythonRNodeCoreBluetoothTransport", native)
        self.assertIn("CBCentralManagerOptionRestoreIdentifierKey", native)
        self.assertNotIn("import ReticulumSwift", native)
        self.assertNotIn("ReticulumPythonRNodeTransport", native)
        reconciler = RECONCILER.read_text()
        self.assertIsNotNone(re.search(
            r"PYTHON_ONLY_SOURCE_METADATA\s*=.*?Sources/PythonBridge/PythonRNodeBLEBridge\.swift",
            reconciler,
            re.DOTALL,
        ))

    def test_app_deploys_bridge_files_and_publishes_live_state(self) -> None:
        source = APP_SERVICES.read_text()
        for name in ("IOSRNodeInterface.py", "IOSRNodeDriver.py"):
            self.assertIn(name, source)
        function = re.search(
            r"public func startRNodeInterface\b.*?"
            r"#elseif COLUMBA_RUNTIME_PYTHON(?P<branch>.*?)#endif",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(function)
        assert function is not None
        branch = function.group("branch")
        self.assertIn("PythonRNodeBLEBridge.shared.setStateHandler", branch)
        self.assertIn("uiInterface.state = .connecting", branch)
        self.assertIn("case .connected:", branch)
        self.assertIn("PythonRNodeBLESessionRegistry.shared.closeAll()", source)
        self.assertIn("if closeAllPythonSessions", source)
        self.assertIn("stopRNodeInterfaceUnlocked(closeAllPythonSessions: true)", source)
        self.assertNotIn("rnodeUnavailableInPythonRuntime", source)


if __name__ == "__main__":
    unittest.main()
