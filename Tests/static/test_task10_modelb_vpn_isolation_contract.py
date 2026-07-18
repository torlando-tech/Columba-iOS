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

from test_modelb_caller_guards_contract import (  # noqa: E402
    atoms,
    guaranteed_for_every_flag_configuration,
    guarantees_flag,
    parse_condition,
    reference_conditions,
    simplify,
    unguarded_references,
)

APP_ROOT = REPOSITORY_ROOT / "Sources/ColumbaApp"
APP_SERVICES = APP_ROOT / "Services/AppServices.swift"
APP_ENTRY = APP_ROOT / "App/ColumbaApp.swift"
ONBOARDING = APP_ROOT / "Views/Onboarding/OnboardingView.swift"
ONBOARDING_VIEW_MODEL = APP_ROOT / "ViewModels/OnboardingViewModel.swift"
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

    def preprocessed(self, source: str, enabled_flags: set[str]) -> str:
        """Evaluate the simple Swift flag matrix used by onboarding sources."""
        output: list[str] = []
        frames: list[tuple[bool, bool]] = []
        active = True
        directive = re.compile(r"\s*#(if|elseif|else|endif)\b\s*(.*)$")

        def evaluate(expression: str) -> bool:
            formula = parse_condition(expression)
            result = simplify(formula, {name: name in enabled_flags for name in atoms(formula)})
            if result[0] != "const":
                raise AssertionError(f"compile condition did not fully evaluate: {expression}")
            return result[1]

        for line in source.splitlines():
            match = directive.fullmatch(line)
            if not match:
                if active:
                    output.append(line)
                continue
            kind, expression = match.groups()
            if kind == "if":
                condition = evaluate(expression)
                frames.append((active, condition))
                active = active and condition
            elif kind == "elseif":
                outer, seen = frames[-1]
                condition = evaluate(expression)
                active = outer and not seen and condition
                frames[-1] = (outer, seen or condition)
            elif kind == "else":
                outer, seen = frames[-1]
                active = outer and not seen
                frames[-1] = (outer, True)
            else:
                active, _ = frames.pop()
        self.assertEqual([], frames, "unbalanced Swift conditional compilation")
        return "\n".join(output)

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
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "StartPath.swift"
            path.write_text(start_body, encoding="utf-8")
            waits = reference_conditions(path, ("ensureBackgroundDeliveryTunnel",))
        self.assertEqual(1, len(waits), "start path must contain exactly one mandatory tunnel wait")
        _, wait_line, condition = waits[0]
        self.assertEqual("await ensureBackgroundDeliveryTunnel()", wait_line)
        self.assertTrue(guarantees_flag(condition, "COLUMBA_RUNTIME_MODEL_B"))
        self.assertTrue(
            guaranteed_for_every_flag_configuration(condition, "COLUMBA_RUNTIME_MODEL_B"),
            "tunnel wait must not be narrowed by DEBUG or another build condition",
        )

        without_model_b = self.preprocessed(start_body, set())
        for forbidden in ("ensureBackgroundDeliveryTunnel", "waitUntilConnected", "tunnel.install()", "tunnel.start()"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, without_model_b)
        self.assertIn("try await backend.start(", without_model_b)

    def test_tunnel_wait_contract_rejects_nested_debug_narrowing(self) -> None:
        source = self.source(APP_SERVICES)
        mutated = source.replace(
            "        await ensureBackgroundDeliveryTunnel()",
            "        #if DEBUG\n        await ensureBackgroundDeliveryTunnel()\n        #endif",
            1,
        )
        self.assertNotEqual(source, mutated)
        start_body = mutated.split("private func startPythonBackend(", 1)[1].split(
            "// Outbound LXMF now goes directly", 1
        )[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "MutatedStartPath.swift"
            path.write_text(start_body, encoding="utf-8")
            waits = reference_conditions(path, ("ensureBackgroundDeliveryTunnel",))
        self.assertEqual(1, len(waits))
        self.assertTrue(guarantees_flag(waits[0][2], "COLUMBA_RUNTIME_MODEL_B"))
        self.assertFalse(
            guaranteed_for_every_flag_configuration(waits[0][2], "COLUMBA_RUNTIME_MODEL_B")
        )

    def test_onboarding_page_matrix_has_no_blank_or_unreachable_page(self) -> None:
        view = self.source(ONBOARDING)
        view_model = self.source(ONBOARDING_VIEW_MODEL)
        for model_b, expected_count in ((False, 5), (True, 6)):
            flags = {"COLUMBA_ONBOARDING_ENABLED"}
            if model_b:
                flags.add("COLUMBA_RUNTIME_MODEL_B")
            rendered_view = self.preprocessed(view, flags)
            rendered_model = self.preprocessed(view_model, flags)
            count_match = re.search(r"static let pageCount = (\d+)", rendered_model)
            if count_match is None:
                self.fail("preprocessed onboarding view model has no pageCount")
            self.assertEqual(expected_count, int(count_match.group(1)))

            switch_body = rendered_view.split("switch viewModel.currentPage {", 1)[1].split(
                "default:", 1
            )[0]
            cases = list(re.finditer(r"^\s*case\s+(\d+):", switch_body, re.MULTILINE))
            self.assertEqual(list(range(expected_count)), [int(case.group(1)) for case in cases])
            for index, case in enumerate(cases):
                body_end = cases[index + 1].start() if index + 1 < len(cases) else len(switch_body)
                body = switch_body[case.end():body_end]
                with self.subTest(model_b=model_b, page=int(case.group(1))):
                    self.assertRegex(body, r"\b(?:Welcome|Identity|Connectivity|Permissions|BackgroundDelivery|Complete)Page\(")

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
