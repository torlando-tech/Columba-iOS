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
    swift_lexical_mask,
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


def function_source(source: str, declaration: str) -> str:
    """Return one Swift function, using lexical masking for brace matching."""
    masked = swift_lexical_mask(source, ())
    declarations = list(re.finditer(declaration, masked))
    if len(declarations) != 1:
        raise AssertionError(
            f"expected exactly one matching function declaration, found {len(declarations)}"
        )
    opening_brace = masked.find("{", declarations[0].end())
    if opening_brace < 0:
        raise AssertionError("matching function has no opening brace")
    depth = 0
    for index in range(opening_brace, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return source[declarations[0].start():index + 1]
    raise AssertionError("matching function has unbalanced braces")


def assert_model_b_tunnel_wait_precedes_backend_start(source: str) -> None:
    """Prove the mandatory Model-B wait is in, and first on, the start path."""
    start_function = function_source(
        source,
        r"\bprivate\s+func\s+startPythonBackend\s*\(",
    )
    masked_function = swift_lexical_mask(start_function, ())
    wait_calls = list(
        re.finditer(r"\bawait\s+ensureBackgroundDeliveryTunnel\s*\(\s*\)", masked_function)
    )
    backend_starts = list(
        re.finditer(r"\btry\s+await\s+backend\.start\s*\(", masked_function)
    )
    if len(wait_calls) != 1:
        raise AssertionError(
            f"startPythonBackend must contain exactly one executable tunnel wait; found {len(wait_calls)}"
        )
    if len(backend_starts) != 1:
        raise AssertionError(
            f"startPythonBackend must contain exactly one executable backend.start; found {len(backend_starts)}"
        )
    if wait_calls[0].start() >= backend_starts[0].start():
        raise AssertionError("Model-B tunnel wait must precede backend.start")

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "StartPythonBackend.swift"
        path.write_text(start_function, encoding="utf-8")
        waits = reference_conditions(path, ("ensureBackgroundDeliveryTunnel",))
    if len(waits) != 1:
        raise AssertionError(f"expected one condition-tracked tunnel wait; found {len(waits)}")
    _, wait_line, condition = waits[0]
    if wait_line != "await ensureBackgroundDeliveryTunnel()":
        raise AssertionError(f"unexpected tunnel-wait expression: {wait_line}")
    if not guarantees_flag(condition, "COLUMBA_RUNTIME_MODEL_B"):
        raise AssertionError("tunnel wait must be active only for Model B")
    if not guaranteed_for_every_flag_configuration(condition, "COLUMBA_RUNTIME_MODEL_B"):
        raise AssertionError("tunnel wait must not be narrowed by DEBUG or another build condition")


def guarded_tunnel_wait_block(source: str) -> str:
    """Extract the complete compile-time block containing the mandatory wait."""
    start_function = function_source(
        source,
        r"\bprivate\s+func\s+startPythonBackend\s*\(",
    )
    match = re.search(
        r"(?ms)^        #if COLUMBA_RUNTIME_MODEL_B\n"
        r"(?:(?!^        #endif\n).)*?"
        r"^        await ensureBackgroundDeliveryTunnel\(\)\n"
        r"^        #endif\n",
        start_function,
    )
    if match is None:
        raise AssertionError("could not locate complete guarded wait block")
    return match.group(0)


def move_guarded_wait_after_backend_start(source: str) -> str:
    """Create the regression mutation without relying on a later source delimiter."""
    start_function = function_source(
        source,
        r"\bprivate\s+func\s+startPythonBackend\s*\(",
    )
    wait_block = guarded_tunnel_wait_block(source)
    mutated_function = start_function.replace(wait_block, "", 1)
    masked = swift_lexical_mask(mutated_function, ())
    start_call = re.search(r"\btry\s+await\s+backend\.start\s*\(", masked)
    if start_call is None:
        raise AssertionError("could not locate backend.start mutation point")
    depth = 0
    for index in range(start_call.end() - 1, len(masked)):
        if masked[index] == "(":
            depth += 1
        elif masked[index] == ")":
            depth -= 1
            if depth == 0:
                mutated_function = (
                    mutated_function[:index + 1]
                    + "\n"
                    + wait_block
                    + mutated_function[index + 1:]
                )
                return source.replace(start_function, mutated_function, 1)
    raise AssertionError("backend.start call has unbalanced parentheses")


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

    def test_model_b_tunnel_wait_precedes_backend_start_in_start_function(self) -> None:
        source = self.source(APP_SERVICES)
        assert_model_b_tunnel_wait_precedes_backend_start(source)

        start_function = function_source(
            source,
            r"\bprivate\s+func\s+startPythonBackend\s*\(",
        )
        without_model_b = self.preprocessed(start_function, set())
        for forbidden in ("ensureBackgroundDeliveryTunnel", "waitUntilConnected", "tunnel.install()", "tunnel.start()"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, without_model_b)
        self.assertIn("try await backend.start(", without_model_b)

    def test_tunnel_wait_contract_rejects_wait_moved_after_backend_start(self) -> None:
        source = self.source(APP_SERVICES)
        mutated = move_guarded_wait_after_backend_start(source)
        self.assertNotEqual(source, mutated)
        with self.assertRaisesRegex(AssertionError, "must precede backend.start"):
            assert_model_b_tunnel_wait_precedes_backend_start(mutated)

    def test_tunnel_wait_order_ignores_decoy_calls_and_comments(self) -> None:
        source = self.source(APP_SERVICES)
        moved = move_guarded_wait_after_backend_start(source)
        decoys = {
            "comment": "    // await ensureBackgroundDeliveryTunnel() before try await backend.start(\n",
            "other function": (
                "    #if COLUMBA_RUNTIME_MODEL_B\n"
                "    private func decoyTunnelWait() async {\n"
                "        await ensureBackgroundDeliveryTunnel()\n"
                "    }\n"
                "    #endif\n"
            ),
        }
        target = "    private func startPythonBackend("
        for name, decoy in decoys.items():
            with self.subTest(decoy=name):
                mutated = moved.replace(target, decoy + target, 1)
                with self.assertRaisesRegex(AssertionError, "must precede backend.start"):
                    assert_model_b_tunnel_wait_precedes_backend_start(mutated)

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
