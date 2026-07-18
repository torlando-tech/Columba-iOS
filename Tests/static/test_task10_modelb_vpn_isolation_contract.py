#!/usr/bin/env python3
"""Task 10 contract: Model B VPN UI/lifecycle is absent from shipping code."""

from pathlib import Path
import re
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
STATIC_TESTS = REPOSITORY_ROOT / "Tests/static"
sys.path.insert(0, str(STATIC_TESTS))

from test_modelb_caller_guards_contract import unguarded_references  # noqa: E402

APP_ROOT = REPOSITORY_ROOT / "Sources/ColumbaApp"
APP_SERVICES = APP_ROOT / "Services/AppServices.swift"
APP_ENTRY = APP_ROOT / "App/ColumbaApp.swift"
ONBOARDING = APP_ROOT / "Views/Onboarding/OnboardingView.swift"
SETTINGS = APP_ROOT / "Views/Settings/SettingsView.swift"
NETWORK_STATUS = APP_ROOT / "Views/Settings/NetworkStatusView.swift"

MODEL_B_ONLY_FILES = (
    APP_ROOT / "Services/TunnelManager.swift",
    APP_ROOT / "Services/ExtensionFrameReader.swift",
    APP_ROOT / "Views/Settings/BackgroundTransportView.swift",
    APP_ROOT / "Views/Components/BackgroundVPNExplainer.swift",
    APP_ROOT / "Views/Onboarding/BackgroundDeliveryGateView.swift",
    APP_ROOT / "Views/Onboarding/BackgroundDeliveryPage.swift",
)

VPN_LIFECYCLE_SYMBOLS = (
    "TunnelManager",
    "ExtensionFrameReader",
    "tunnelManager",
    "extensionFrameReader",
    "ensureTunnelManager",
    "ensureBackgroundDeliveryTunnel",
    "enableBackgroundDeliveryForOnboarding",
    "approveBackgroundDelivery",
    "needsBackgroundDeliveryApproval",
    "applyTunnelModeToInterfaces",
    "reapplyTunnelModeIfActive",
    "BackgroundDeliveryGateView",
    "BackgroundDeliveryPage",
    "BackgroundTransportView",
    "VPNNotCommercialExplainer",
    "VPNBadgeExplainer",
    "VPNExplainerUI",
    "copyExtensionDiagToDocuments",
    "startExtDiagLiveCopy",
    "NETunnelProviderManager",
    "NEVPNStatus",
)


class Task10ModelBVPNIsolationContractTests(unittest.TestCase):
    def source(self, path: Path) -> str:
        return path.read_text(encoding="utf-8")

    def references(self, source: str, symbols: tuple[str, ...]) -> list[tuple[int, str]]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Contract.swift"
            path.write_text(source, encoding="utf-8")
            return unguarded_references(path, symbols)

    def test_app_side_vpn_guards_use_only_the_canonical_model_b_flag(self) -> None:
        for path in APP_ROOT.rglob("*.swift"):
            source = self.source(path)
            with self.subTest(path=path.relative_to(REPOSITORY_ROOT)):
                self.assertNotRegex(
                    source,
                    r"^\s*#if\s+.*\bENABLE_NETWORK_EXTENSION\b",
                    "generic extension capability must not select app architecture",
                )

    def test_model_b_only_vpn_files_are_definition_guarded(self) -> None:
        for path in MODEL_B_ONLY_FILES:
            source = self.source(path)
            first_directive = re.search(r"^\s*#if\s+(.+)$", source, re.MULTILINE)
            with self.subTest(path=path.relative_to(REPOSITORY_ROOT)):
                self.assertIsNotNone(first_directive)
                self.assertIn("COLUMBA_RUNTIME_MODEL_B", first_directive.group(1))

    def test_shared_shipping_sources_reference_vpn_surface_only_in_model_b_regions(self) -> None:
        shared_sources = (APP_SERVICES, APP_ENTRY, ONBOARDING, SETTINGS, NETWORK_STATUS)
        for path in shared_sources:
            source = self.source(path)
            references = unguarded_references(path, VPN_LIFECYCLE_SYMBOLS)
            with self.subTest(path=path.relative_to(REPOSITORY_ROOT)):
                self.assertEqual([], references)

    def test_extension_log_copy_definitions_and_launch_calls_are_model_b_only(self) -> None:
        services = self.source(APP_SERVICES)
        entry = self.source(APP_ENTRY)
        for source, symbols in (
            (services, ("copyExtensionDiagToDocuments", "startExtDiagLiveCopy")),
            (entry, ("copyExtensionDiagToDocuments", "startExtDiagLiveCopy")),
        ):
            self.assertEqual([], self.references(source, symbols))

    def test_python_backend_start_path_has_no_tunnel_wait_or_lifecycle_call(self) -> None:
        source = self.source(APP_SERVICES)
        start_body = source.split("private func startPythonBackend(", 1)[1].split(
            "// Outbound LXMF now goes directly", 1
        )[0]
        model_b_regions = list(
            re.finditer(
                r"#if COLUMBA_RUNTIME_MODEL_B\n(?P<body>.*?)\n\s*#endif",
                start_body,
                re.DOTALL,
            )
        )
        wait_regions = [
            match for match in model_b_regions
            if "await ensureBackgroundDeliveryTunnel()" in match.group("body")
        ]
        self.assertEqual(1, len(wait_regions))
        without_model_b = start_body
        for match in reversed(model_b_regions):
            without_model_b = (
                without_model_b[:match.start()] + without_model_b[match.end():]
            )
        for forbidden in ("ensureBackgroundDeliveryTunnel", "waitUntilConnected", "tunnel.install()", "tunnel.start()"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, without_model_b)
        self.assertIn("try await backend.start(", without_model_b)

    def test_model_b_product_retains_gate_status_onboarding_and_manager_paths(self) -> None:
        self.assertIn("BackgroundDeliveryGateView(appServices: appServices)", self.source(APP_ENTRY))
        self.assertIn("BackgroundDeliveryPage(", self.source(ONBOARDING))
        self.assertIn("backgroundTransportCard()", self.source(SETTINGS))
        self.assertIn("Background Transport Active", self.source(NETWORK_STATUS))
        manager = self.source(APP_ROOT / "Services/TunnelManager.swift")
        for required in (
            "NETunnelProviderManager.loadAllFromPreferences()",
            "public func install() async throws",
            "public func start() async throws",
        ):
            self.assertIn(required, manager)

    def test_guard_analyzer_mutation_rejects_shipping_leak_and_accepts_model_b_guard(self) -> None:
        mutation = "TunnelManager().load()\n"
        self.assertTrue(self.references(mutation, VPN_LIFECYCLE_SYMBOLS))
        guarded = "#if COLUMBA_RUNTIME_MODEL_B\n" + mutation + "#endif\n"
        self.assertEqual([], self.references(guarded, VPN_LIFECYCLE_SYMBOLS))


if __name__ == "__main__":
    unittest.main()
