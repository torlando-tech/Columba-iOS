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


def lexical_brace_depth(masked_source: str, offset: int) -> int:
    """Return brace depth at an executable offset, failing closed if unbalanced."""
    depth = 0
    for character in masked_source[:offset]:
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth < 0:
                raise AssertionError("source has an unmatched closing brace")
    return depth


def lexical_block_ancestry(masked_source: str, offset: int) -> list[tuple[int, str]]:
    """Return the lexically enclosing brace events and their fail-closed kinds."""
    ancestry: list[tuple[int, str]] = []
    previous_event = 0
    for index, character in enumerate(masked_source[:offset]):
        if character == "{":
            prefix = masked_source[previous_event:index]
            if re.search(r"\bdo\s*$", prefix):
                kind = "do"
            elif re.search(r"\b(?:func|init|deinit|subscript)\b", prefix):
                kind = "function"
            else:
                kind = "other"
            ancestry.append((index, kind))
            previous_event = index + 1
        elif character == "}":
            if not ancestry:
                raise AssertionError("source has an unmatched closing brace")
            ancestry.pop()
            previous_event = index + 1
    return ancestry


def assert_model_b_tunnel_wait_precedes_backend_start(source: str) -> None:
    """Prove the mandatory Model-B wait is direct, awaited, and first on the start path."""
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
    backend_ancestry = lexical_block_ancestry(
        masked_function, backend_starts[0].start()
    )
    if (
        len(backend_ancestry) != 2
        or backend_ancestry[0][1] != "function"
        or backend_ancestry[1][1] != "do"
    ):
        raise AssertionError(
            "backend.start must remain in the direct canonical do block after the tunnel wait, not in a local function, closure, Task, async let, defer, or nested helper"
        )
    if wait_calls[0].start() >= backend_starts[0].start():
        raise AssertionError("Model-B tunnel wait must precede backend.start")
    if lexical_brace_depth(masked_function, wait_calls[0].start()) != 1:
        raise AssertionError(
            "Model-B tunnel wait must be a direct method-body statement, not nested in a closure, Task, local function, or control block"
        )
    if backend_ancestry[1][0] <= wait_calls[0].start():
        raise AssertionError(
            "backend.start canonical do block must open after the direct tunnel wait"
        )

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


def replace_guarded_wait(source: str, replacement: str) -> str:
    """Replace the canonical guarded wait with an adversarial arrangement."""
    wait_block = guarded_tunnel_wait_block(source)
    mutated = source.replace(wait_block, replacement, 1)
    if mutated == source:
        raise AssertionError("tunnel-wait mutation did not change source")
    return mutated


def assert_onboarding_completion_cases_are_branch_local(source: str) -> None:
    """Require each runtime branch to give its completion case a concrete body."""
    conditional = re.search(
        r"(?ms)^\s*#if COLUMBA_RUNTIME_MODEL_B\s*$"
        r"(?P<model_b>.*?)"
        r"^\s*#else\s*$"
        r"(?P<shipping>.*?)"
        r"^\s*#endif\s*$",
        source,
    )
    if conditional is None:
        raise AssertionError("could not locate Model-B onboarding page conditional")

    expected_cases = {
        "Model B": (conditional.group("model_b"), (4, 5), 5),
        "shipping": (conditional.group("shipping"), (4,), 4),
    }
    for flavor, (branch, expected_indices, completion_index) in expected_cases.items():
        cases = list(re.finditer(r"^\s*case\s+(\d+):", branch, re.MULTILINE))
        indices = tuple(int(case.group(1)) for case in cases)
        if indices != expected_indices:
            raise AssertionError(
                f"{flavor} onboarding branch must contain cases {expected_indices}; found {indices}"
            )
        for index, case in enumerate(cases):
            body_end = cases[index + 1].start() if index + 1 < len(cases) else len(branch)
            body = branch[case.end():body_end]
            if not body.strip():
                raise AssertionError(
                    f"{flavor} onboarding case {case.group(1)} must have a branch-local statement"
                )
            if int(case.group(1)) == completion_index and not re.search(
                r"^\s*completePage\s*$", body, re.MULTILINE
            ):
                raise AssertionError(
                    f"{flavor} onboarding completion case must render branch-local completePage"
                )


def relocate_backend_start(
    source: str,
    container: str,
    replacement: str,
    *,
    before_wait: str = "",
    declare_before_wait: bool = False,
) -> str:
    """Move the unique backend.start expression into an adversarial nested container."""
    start_function = function_source(
        source,
        r"\bprivate\s+func\s+startPythonBackend\s*\(",
    )
    masked = swift_lexical_mask(start_function, ())
    start_call = re.search(r"\btry\s+await\s+backend\.start\s*\(", masked)
    if start_call is None:
        raise AssertionError("could not locate backend.start mutation point")
    depth = 0
    call_end = None
    for index in range(start_call.end() - 1, len(masked)):
        if masked[index] == "(":
            depth += 1
        elif masked[index] == ")":
            depth -= 1
            if depth == 0:
                call_end = index + 1
                break
    if call_end is None:
        raise AssertionError("backend.start call has unbalanced parentheses")

    expression = start_function[start_call.start():call_end]
    mutated_function = (
        start_function[:start_call.start()] + replacement + start_function[call_end:]
    )
    wait_block = guarded_tunnel_wait_block(source)
    insertion = container.replace("BACKEND_START_EXPRESSION", expression)
    if declare_before_wait:
        wait_replacement = insertion + before_wait + wait_block
    else:
        wait_replacement = before_wait + wait_block + insertion
    mutated_function = mutated_function.replace(wait_block, wait_replacement, 1)
    if mutated_function == start_function:
        raise AssertionError("backend.start relocation mutation did not change source")
    return source.replace(start_function, mutated_function, 1)


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

    def test_tunnel_wait_contract_rejects_uninvoked_nested_closure(self) -> None:
        source = self.source(APP_SERVICES)
        mutated = replace_guarded_wait(
            source,
            "        let deferredTunnelWait: () async -> Void = {\n"
            "            #if COLUMBA_RUNTIME_MODEL_B\n"
            "            await ensureBackgroundDeliveryTunnel()\n"
            "            #endif\n"
            "        }\n"
            "        _ = deferredTunnelWait\n",
        )
        with self.assertRaisesRegex(AssertionError, "direct method-body statement"):
            assert_model_b_tunnel_wait_precedes_backend_start(mutated)

    def test_tunnel_wait_contract_rejects_deferred_task_arrangements(self) -> None:
        source = self.source(APP_SERVICES)
        replacements = {
            "task": (
                "        #if COLUMBA_RUNTIME_MODEL_B\n"
                "        Task {\n"
                "            await ensureBackgroundDeliveryTunnel()\n"
                "        }\n"
                "        #endif\n"
            ),
            "invoked closure in task": (
                "        #if COLUMBA_RUNTIME_MODEL_B\n"
                "        let deferredTunnelWait: () async -> Void = {\n"
                "            await ensureBackgroundDeliveryTunnel()\n"
                "        }\n"
                "        Task { await deferredTunnelWait() }\n"
                "        #endif\n"
            ),
            "async let": (
                "        #if COLUMBA_RUNTIME_MODEL_B\n"
                "        async let deferredTunnelWait: Void = ensureBackgroundDeliveryTunnel()\n"
                "        _ = deferredTunnelWait\n"
                "        #endif\n"
            ),
        }
        for name, replacement in replacements.items():
            with self.subTest(arrangement=name):
                mutated = replace_guarded_wait(source, replacement)
                with self.assertRaises(AssertionError):
                    assert_model_b_tunnel_wait_precedes_backend_start(mutated)

    def test_backend_start_contract_rejects_exact_pre_wait_helper_mutation(self) -> None:
        source = self.source(APP_SERVICES)
        mutated = relocate_backend_start(
            source,
            "\n"
            "        func startBeforeTunnel() async throws -> LocalInfo {\n"
            "            return BACKEND_START_EXPRESSION\n"
            "        }\n",
            "previouslyStarted!",
            before_wait="        let previouslyStarted = try? await startBeforeTunnel()\n\n",
        )
        with self.assertRaisesRegex(AssertionError, "direct canonical do block"):
            assert_model_b_tunnel_wait_precedes_backend_start(mutated)

    def test_backend_start_contract_rejects_local_helper_relocations(self) -> None:
        source = self.source(APP_SERVICES)
        mutations = {
            "local function declared before wait": relocate_backend_start(
                source,
                "        func relocatedBackendStart() async throws -> LocalInfo {\n"
                "            return BACKEND_START_EXPRESSION\n"
                "        }\n\n",
                "try await relocatedBackendStart()",
                declare_before_wait=True,
            ),
            "local function declared after wait": relocate_backend_start(
                source,
                "\n        func relocatedBackendStart() async throws -> LocalInfo {\n"
                "            return BACKEND_START_EXPRESSION\n"
                "        }\n",
                "try await relocatedBackendStart()",
            ),
            "local function wrapping do": relocate_backend_start(
                source,
                "\n        func relocatedBackendStart() async throws -> LocalInfo {\n"
                "            do {\n"
                "                return BACKEND_START_EXPRESSION\n"
                "            }\n"
                "        }\n",
                "try await relocatedBackendStart()",
            ),
            "closure wrapping do": relocate_backend_start(
                source,
                "\n        let relocatedBackendStart: () async throws -> LocalInfo = {\n"
                "            do {\n"
                "                return BACKEND_START_EXPRESSION\n"
                "            }\n"
                "        }\n",
                "try await relocatedBackendStart()",
            ),
            "Task wrapping do": relocate_backend_start(
                source,
                "\n        let relocatedBackendStart = Task {\n"
                "            do {\n"
                "                return BACKEND_START_EXPRESSION\n"
                "            }\n"
                "        }\n",
                "try await relocatedBackendStart.value",
            ),
        }
        for name, mutated in mutations.items():
            with self.subTest(relocation=name):
                with self.assertRaisesRegex(AssertionError, "direct canonical do block"):
                    assert_model_b_tunnel_wait_precedes_backend_start(mutated)

    def test_tunnel_wait_direct_depth_ignores_comment_and_string_braces(self) -> None:
        source = self.source(APP_SERVICES)
        wait_block = guarded_tunnel_wait_block(source)
        mutated = replace_guarded_wait(
            source,
            "        let braceDecoys = (\"}\", #\"{\"#) // }}}\n"
            "        /* {{{ */\n"
            + wait_block,
        )
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
        assert_onboarding_completion_cases_are_branch_local(view)
        self.assertIn("private var completePage: some View {", view)
        self.assertEqual(1, view.count("CompletePage("), "completion UI must remain shared")
        for required_flow in (
            "await viewModel.prepareIdentity(identityManager: identityManager)",
            "try await viewModel.completeOnboarding(",
            "onComplete()",
        ):
            self.assertIn(required_flow, view)
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
                    self.assertRegex(
                        body,
                        r"\b(?:(?:Welcome|Identity|Connectivity|Permissions|BackgroundDelivery)Page\(|completePage\b)",
                    )

    def test_onboarding_contract_rejects_completion_body_after_conditional(self) -> None:
        view = self.source(ONBOARDING)
        canonical = (
            "                    case 5:\n"
            "                        completePage\n"
            "                    #else\n"
            "                    case 4:\n"
            "                        completePage\n"
            "                    #endif"
        )
        legacy = (
            "                    case 5:\n"
            "                    #else\n"
            "                    case 4:\n"
            "                    #endif\n"
            "                        completePage"
        )
        mutated = view.replace(canonical, legacy, 1)
        self.assertNotEqual(view, mutated, "completion-case mutation did not change source")
        with self.assertRaisesRegex(AssertionError, "branch-local statement"):
            assert_onboarding_completion_cases_are_branch_local(mutated)

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
