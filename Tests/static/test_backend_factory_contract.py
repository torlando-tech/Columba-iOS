"""Both runtime modes use one facade and vary only command transport."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class BackendFactoryContractTests(unittest.TestCase):
    def test_both_hosts_use_one_facade(self):
        source = (ROOT / "Sources/ColumbaApp/Services/BackendFactory.swift").read_text()
        self.assertIn("switch mode", source)
        self.assertEqual(source.count("return ProxyRnsBackend("), 2)
        self.assertIn("LocalNodeAdapter()", source)
        self.assertNotIn("#if", source)
        self.assertNotIn("PythonRNSBackend", source)

    def test_both_hosts_use_one_command_implementation(self):
        local = (ROOT / "Sources/RNSHost/LocalNodeAdapter.swift").read_text()
        tunnel = (ROOT / "Sources/ColumbaNetworkExtension/PacketTunnelProvider.swift").read_text()
        self.assertIn("NodeCommandDispatcher.dispatch", local)
        self.assertIn("NodeCommandDispatcher.dispatch", tunnel)
        self.assertNotIn("switch request", local)
        self.assertNotIn("switch request", tunnel)
    def test_ui_mirror_does_not_stop_the_host_radio(self):
        source = (ROOT / "Sources/ColumbaApp/Services/AppServices.swift").read_text()
        mirror = source.split("private func stopBLEInterfaceUnlocked() async", 1)[1].split("#endif", 1)[0]
        self.assertNotIn("SwiftBLEBridge.shared", mirror)
