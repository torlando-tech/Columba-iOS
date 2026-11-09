#!/usr/bin/env python3
"""Shipping Python-runtime RNode native bridge contracts."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONFIG_WRITER = ROOT / "Sources/ColumbaApp/Services/PythonConfigWriter.swift"
PY_INTERFACE = ROOT / "app/rnode/IOSRNodeInterface.py"
PY_DRIVER = ROOT / "app/rnode/IOSRNodeDriver.py"


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


if __name__ == "__main__":
    unittest.main()
