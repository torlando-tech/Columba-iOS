#!/usr/bin/env python3
"""Linux-runnable contract checks for host entitlement flavor isolation."""

from pathlib import Path
import plistlib
import re
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RESOURCES = REPOSITORY_ROOT / "Sources/ColumbaApp/Resources"
SHIPPING_ENTITLEMENTS = RESOURCES / "ColumbaApp.entitlements"
MODEL_B_ENTITLEMENTS = RESOURCES / "ColumbaModelBApp.entitlements"
PROJECT_FILE = REPOSITORY_ROOT / "Columba.xcodeproj/project.pbxproj"
NETWORK_EXTENSION_KEY = "com.apple.developer.networking.networkextension"
PACKET_TUNNEL_PROVIDER = "packet-tunnel-provider"


class HostEntitlementsContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with SHIPPING_ENTITLEMENTS.open("rb") as plist_file:
            cls.shipping = plistlib.load(plist_file)
        with MODEL_B_ENTITLEMENTS.open("rb") as plist_file:
            cls.model_b = plistlib.load(plist_file)
        cls.project = PROJECT_FILE.read_text(encoding="utf-8")

    def test_shipping_host_does_not_request_network_extension(self) -> None:
        self.assertNotIn(NETWORK_EXTENSION_KEY, self.shipping)

    def test_model_b_host_retains_packet_tunnel_provider(self) -> None:
        self.assertEqual(
            self.model_b.get(NETWORK_EXTENSION_KEY),
            [PACKET_TUNNEL_PROVIDER],
        )

    def test_shared_host_entitlements_remain_identical(self) -> None:
        shared_keys = (
            "com.apple.security.application-groups",
            "keychain-access-groups",
        )
        for key in shared_keys:
            with self.subTest(key=key):
                self.assertIn(key, self.shipping)
                self.assertEqual(self.shipping[key], self.model_b[key])

    def test_columba_app_configurations_use_flavor_specific_entitlements(self) -> None:
        for filename in ("ColumbaApp.entitlements", "ColumbaModelBApp.entitlements"):
            with self.subTest(file_reference=filename):
                self.assertRegex(
                    self.project,
                    rf"PBXFileReference;[^\n]*path = {re.escape(filename)};",
                )

        configuration_list = re.search(
            r'BCLST /\* Build configuration list for PBXNativeTarget "ColumbaApp" \*/ = '
            r"\{.*?buildConfigurations = \((.*?)\);",
            self.project,
            flags=re.DOTALL,
        )
        if configuration_list is None:
            self.fail("ColumbaApp build configuration list is missing")

        expected_paths = {
            "Debug": "Sources/ColumbaApp/Resources/ColumbaApp.entitlements",
            "Release": "Sources/ColumbaApp/Resources/ColumbaApp.entitlements",
            "Debug-Swift": "Sources/ColumbaApp/Resources/ColumbaModelBApp.entitlements",
            "Release-Swift": "Sources/ColumbaApp/Resources/ColumbaModelBApp.entitlements",
        }
        entries = re.findall(
            r"([A-Za-z0-9]+) /\* (Debug|Release|Debug-Swift|Release-Swift) \*/",
            configuration_list.group(1),
        )
        self.assertEqual({name for _, name in entries}, set(expected_paths))

        for identifier, name in entries:
            with self.subTest(configuration=name):
                build_configuration = re.search(
                    rf"{re.escape(identifier)} /\* {re.escape(name)} \*/ = "
                    r"\{(.*?)\n\s*\};",
                    self.project,
                    flags=re.DOTALL,
                )
                if build_configuration is None:
                    self.fail(f"{name} build configuration is missing")
                self.assertIn(
                    f"CODE_SIGN_ENTITLEMENTS = {expected_paths[name]};",
                    build_configuration.group(1),
                )


if __name__ == "__main__":
    unittest.main()
