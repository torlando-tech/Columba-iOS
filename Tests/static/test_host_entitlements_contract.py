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
SHIPPING_ENTITLEMENTS_EXPECTED = {
    "com.apple.security.application-groups": ["group.network.columba.Columba"],
    "keychain-access-groups": [
        "$(AppIdentifierPrefix)network.columba.Columba.shared"
    ],
}
MODEL_B_ENTITLEMENTS_EXPECTED = {
    **SHIPPING_ENTITLEMENTS_EXPECTED,
    "com.apple.developer.networking.networkextension": [
        "packet-tunnel-provider"
    ],
}


class HostEntitlementsContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with SHIPPING_ENTITLEMENTS.open("rb") as plist_file:
            cls.shipping = plistlib.load(plist_file)
        with MODEL_B_ENTITLEMENTS.open("rb") as plist_file:
            cls.model_b = plistlib.load(plist_file)
        cls.project = PROJECT_FILE.read_text(encoding="utf-8")

    def test_shipping_host_entitlements_match_complete_contract(self) -> None:
        self.assertEqual(self.shipping, SHIPPING_ENTITLEMENTS_EXPECTED)

    def test_model_b_host_entitlements_match_complete_contract(self) -> None:
        self.assertEqual(self.model_b, MODEL_B_ENTITLEMENTS_EXPECTED)

    def test_app_targets_use_isolated_entitlements(self) -> None:
        for filename in ("ColumbaApp.entitlements", "ColumbaModelBApp.entitlements"):
            with self.subTest(file_reference=filename):
                self.assertRegex(
                    self.project,
                    rf"PBXFileReference;[^\n]*path = {re.escape(filename)};",
                )

        target_contracts = {
            "ColumbaApp": "Sources/ColumbaApp/Resources/ColumbaApp.entitlements",
            "ColumbaModelBApp": (
                "Sources/ColumbaApp/Resources/ColumbaModelBApp.entitlements"
            ),
        }
        for target_name, expected_path in target_contracts.items():
            with self.subTest(target=target_name):
                configuration_list = re.search(
                    rf'([A-Za-z0-9]+) /\* Build configuration list for PBXNativeTarget '
                    rf'"{re.escape(target_name)}" \*/ = '
                    r"\{.*?buildConfigurations = \((.*?)\);",
                    self.project,
                    flags=re.DOTALL,
                )
                if configuration_list is None:
                    self.fail(f"{target_name} build configuration list is missing")

                entries = re.findall(
                    r"([A-Za-z0-9]+) /\* (Debug|Release) \*/",
                    configuration_list.group(2),
                )
                self.assertEqual(
                    {name for _, name in entries},
                    {"Debug", "Release"},
                )

                for identifier, name in entries:
                    with self.subTest(target=target_name, configuration=name):
                        build_configuration = re.search(
                            rf"{re.escape(identifier)} /\* {re.escape(name)} \*/ = "
                            r"\{(.*?)\n\s*\};",
                            self.project,
                            flags=re.DOTALL,
                        )
                        if build_configuration is None:
                            self.fail(f"{target_name} {name} configuration is missing")
                        self.assertIn(
                            f"CODE_SIGN_ENTITLEMENTS = {expected_path};",
                            build_configuration.group(1),
                        )


if __name__ == "__main__":
    unittest.main()
