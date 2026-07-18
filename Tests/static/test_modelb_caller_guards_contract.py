#!/usr/bin/env python3
"""Static compile-region contract for declarations absent from the Python target."""

from functools import lru_cache
from pathlib import Path
import re
import tempfile
import unittest
from typing import TypedDict


ROOT = Path(__file__).resolve().parents[2]
CALLERS = (
    ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift",
    ROOT / "Sources/ColumbaApp/Services/AppServices.swift",
    ROOT / "Sources/ColumbaApp/Services/PropagationNodeManager.swift",
)
MODEL_B_FLAG = "COLUMBA_RUNTIME_MODEL_B"
MODEL_B_DECLARATIONS = (
    "SwiftRNSBackend",
    "NomadNetFetch",
    "ModelBRNodeService",
    "AppGroupRNodeSeamTransport",
    "AppGroupRNodeSeamWire",
    "AppGroupRNodeServer",
    "RNodeSeamConfig",
    "RNodeLinkState",
    "PropagationSeamConfig",
    "PropagationSyncStateSnapshot",
    "ModelBInboundReplay",
)

Formula = tuple
TRUE: Formula = ("const", True)


class ConditionalFrame(TypedDict):
    outer: Formula
    seen: Formula
    has_else: bool


def swift_lexical_mask(source: str) -> str:
    """Blank Swift literal text/comments but preserve code inside interpolation."""
    output = list(source)
    index = 0
    block_depth = 0
    state = "code"
    hashes = 0
    literal_start = 0
    interpolation_literals: list[tuple[str, int, int]] = []
    interpolation_depths: list[int] = []

    def blank(position: int) -> None:
        if output[position] not in "\r\n":
            output[position] = " "

    def blank_span(start: int, end: int) -> None:
        for position in range(start, end):
            blank(position)

    def exact_extended_close(position: int, marker: str) -> bool:
        closing = marker + ("#" * hashes)
        return source.startswith(closing, position) and not source.startswith(
            "#", position + len(closing)
        )

    def interpolation_length(position: int, delimiter_hashes: int) -> int:
        introducer = "\\" + ("#" * delimiter_hashes) + "("
        return len(introducer) if source.startswith(introducer, position) else 0

    def begin_interpolation(position: int, length: int) -> int:
        nonlocal state
        blank_span(position, position + length)
        interpolation_literals.append((state, hashes, literal_start))
        interpolation_depths.append(1)
        state = "code"
        return position + length

    def starts_bare_regex(position: int) -> bool:
        """Recognize `/.../` only where Swift expects an expression operand."""
        previous = position - 1
        while previous >= 0 and source[previous] in " \t":
            previous -= 1
        if previous < 0 or source[previous] in "\r\n=([{,:;!?&|":
            return True
        word = re.search(r"([A-Za-z_][A-Za-z0-9_]*)$", source[: previous + 1])
        return bool(
            word
            and word.group(1) in {"case", "return", "throw", "try", "await", "in"}
        )

    while index < len(source):
        if block_depth:
            if source.startswith("/*", index):
                blank_span(index, index + 2)
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                blank_span(index, index + 2)
                block_depth -= 1
                index += 2
            else:
                blank(index)
                index += 1
            continue

        if state == "line_comment":
            blank(index)
            if source[index] in "\r\n":
                state = "code"
            index += 1
            continue

        if state == "string":
            length = interpolation_length(index, 0)
            if length:
                index = begin_interpolation(index, length)
            elif source[index] in "\r\n":
                raise ValueError("unterminated Swift string literal before newline")
            elif source[index] == "\\" and index + 1 < len(source):
                blank_span(index, index + 2)
                index += 2
            elif source[index] == '"':
                blank(index)
                state = "code"
                index += 1
            else:
                blank(index)
                index += 1
            continue

        if state == "multiline_string":
            length = interpolation_length(index, 0)
            if length:
                index = begin_interpolation(index, length)
            elif source[index] == "\\" and index + 1 < len(source):
                blank_span(index, index + 2)
                index += 2
            elif source.startswith('"""', index):
                blank_span(index, index + 3)
                index += 3
                state = "code"
            else:
                blank(index)
                index += 1
            continue

        if state in {"raw_string", "raw_multiline_string", "extended_regex"}:
            if state == "raw_string" and source[index] in "\r\n":
                raise ValueError("unterminated Swift raw string literal before newline")
            marker = {
                "raw_string": '"',
                "raw_multiline_string": '"""',
                "extended_regex": "/",
            }[state]
            length = interpolation_length(index, hashes)
            if length:
                index = begin_interpolation(index, length)
            elif exact_extended_close(index, marker):
                end = index + len(marker) + hashes
                blank_span(index, end)
                index = end
                state = "code"
                hashes = 0
            else:
                blank(index)
                index += 1
            continue

        if state == "bare_regex":
            length = interpolation_length(index, 0)
            if length:
                index = begin_interpolation(index, length)
            elif source[index] == "\\" and index + 1 < len(source):
                blank_span(index, index + 2)
                index += 2
            elif source[index] == "/":
                blank(index)
                literal = source[literal_start:index + 1]
                if any(
                    re.search(rf"\b{re.escape(token)}\b", literal)
                    for token in MODEL_B_DECLARATIONS
                ):
                    raise ValueError(
                        "ambiguous Swift bare regex contains a tracked declaration"
                    )
                state = "code"
                index += 1
            elif source[index] in "\r\n":
                raise ValueError("unterminated Swift bare regex literal before newline")
            else:
                blank(index)
                index += 1
            continue

        if interpolation_depths and source[index] == "(":
            interpolation_depths[-1] += 1
            index += 1
            continue
        if interpolation_depths and source[index] == ")":
            interpolation_depths[-1] -= 1
            if interpolation_depths[-1] == 0:
                blank(index)
                interpolation_depths.pop()
                state, hashes, literal_start = interpolation_literals.pop()
            index += 1
            continue

        if source[index] == "#":
            end = index
            while end < len(source) and source[end] == "#":
                end += 1
            delimiter_hashes = end - index
            if source.startswith('"""', end):
                hashes = delimiter_hashes
                blank_span(index, end + 3)
                index = end + 3
                state = "raw_multiline_string"
            elif end < len(source) and source[end] == '"':
                hashes = delimiter_hashes
                blank_span(index, end + 1)
                index = end + 1
                state = "raw_string"
            elif end < len(source) and source[end] == "/":
                hashes = delimiter_hashes
                blank_span(index, end + 1)
                index = end + 1
                state = "extended_regex"
            else:
                index += 1
        elif source.startswith("//", index):
            blank_span(index, index + 2)
            index += 2
            state = "line_comment"
        elif source.startswith("/*", index):
            blank_span(index, index + 2)
            index += 2
            block_depth = 1
        elif source.startswith('"""', index):
            blank_span(index, index + 3)
            index += 3
            state = "multiline_string"
        elif source[index] == '"':
            blank(index)
            index += 1
            state = "string"
        elif source[index] == "/" and starts_bare_regex(index):
            literal_start = index
            blank(index)
            index += 1
            state = "bare_regex"
        else:
            index += 1

    if interpolation_depths:
        raise ValueError("unterminated Swift interpolation")
    if block_depth:
        raise ValueError("unterminated Swift block comment")
    errors = {
        "multiline_string": "unterminated Swift multiline string",
        "string": "unterminated Swift string literal",
        "raw_string": "unterminated Swift raw string literal",
        "raw_multiline_string": "unterminated Swift raw multiline string",
        "extended_regex": "unterminated Swift extended regex literal",
        "bare_regex": "unterminated Swift bare regex literal",
    }
    if state in errors:
        raise ValueError(errors[state])
    return "".join(output)


class ConditionParser:
    """Parse the boolean subset used by Swift conditional-compilation guards."""

    TOKEN = re.compile(r"\s*(\&\&|\|\||!|\(|\)|[A-Za-z_][A-Za-z0-9_.]*)")

    def __init__(self, expression: str):
        self.expression = expression
        self.tokens = self._tokenize(expression)
        self.index = 0

    @classmethod
    def _tokenize(cls, expression: str) -> list[str]:
        tokens: list[str] = []
        position = 0
        while position < len(expression):
            match = cls.TOKEN.match(expression, position)
            if not match:
                if expression[position:].strip() == "":
                    break
                raise ValueError(f"unsupported token near {expression[position:]!r}")
            token = match.group(1)
            position = match.end()
            # Treat platform predicates such as os(iOS) and canImport(Foo) as atoms.
            if re.match(r"[A-Za-z_]", token) and position < len(expression) and expression[position] == "(":
                depth = 0
                end = position
                while end < len(expression):
                    character = expression[end]
                    if character == "(":
                        depth += 1
                    elif character == ")":
                        depth -= 1
                        if depth == 0:
                            end += 1
                            break
                    end += 1
                if depth != 0:
                    raise ValueError(f"unbalanced predicate call in {expression!r}")
                token += expression[position:end]
                position = end
            tokens.append(token)
        return tokens

    def parse(self) -> Formula:
        if not self.tokens:
            raise ValueError("empty compile condition")
        result = self._parse_or()
        if self.index != len(self.tokens):
            raise ValueError(f"unexpected token {self.tokens[self.index]!r}")
        return result

    def _accept(self, token: str) -> bool:
        if self.index < len(self.tokens) and self.tokens[self.index] == token:
            self.index += 1
            return True
        return False

    def _parse_or(self) -> Formula:
        result = self._parse_and()
        while self._accept("||"):
            result = ("or", result, self._parse_and())
        return result

    def _parse_and(self) -> Formula:
        result = self._parse_unary()
        while self._accept("&&"):
            result = ("and", result, self._parse_unary())
        return result

    def _parse_unary(self) -> Formula:
        if self._accept("!"):
            return ("not", self._parse_unary())
        if self._accept("("):
            result = self._parse_or()
            if not self._accept(")"):
                raise ValueError("missing closing parenthesis")
            return result
        if self.index >= len(self.tokens):
            raise ValueError("missing condition operand")
        token = self.tokens[self.index]
        if token in {"&&", "||", ")"}:
            raise ValueError(f"unexpected token {token!r}")
        self.index += 1
        return ("atom", token)


def parse_condition(expression: str) -> Formula:
    return ConditionParser(expression.strip()).parse()


def combine(operator: str, left: Formula, right: Formula) -> Formula:
    return (operator, left, right)


def negate(formula: Formula) -> Formula:
    return ("not", formula)


def atoms(formula: Formula) -> set[str]:
    kind = formula[0]
    if kind == "atom":
        return {formula[1]}
    if kind == "const":
        return set()
    if kind == "not":
        return atoms(formula[1])
    return atoms(formula[1]) | atoms(formula[2])


def simplify(formula: Formula, values: dict[str, bool]) -> Formula:
    """Substitute known atoms and simplify Boolean identities structurally."""
    kind = formula[0]
    if kind == "const":
        return formula
    if kind == "atom":
        return ("const", values[formula[1]]) if formula[1] in values else formula
    if kind == "not":
        operand = simplify(formula[1], values)
        if operand[0] == "const":
            return ("const", not operand[1])
        if operand[0] == "not":
            return operand[1]
        return ("not", operand)

    left = simplify(formula[1], values)
    right = simplify(formula[2], values)
    if kind == "and":
        if left == TRUE:
            return right
        if right == TRUE:
            return left
        if left[0] == "const" and not left[1]:
            return left
        if right[0] == "const" and not right[1]:
            return right
    elif kind == "or":
        if left[0] == "const" and left[1]:
            return left
        if right[0] == "const" and right[1]:
            return right
        if left[0] == "const" and not left[1]:
            return right
        if right[0] == "const" and not right[1]:
            return left
    else:
        raise AssertionError(f"unknown formula node {kind}")
    if left == right:
        return left
    return (kind, left, right)


@lru_cache(maxsize=None)
def satisfiable(formula: Formula) -> bool:
    """Decide satisfiability with memoized, short-circuiting Shannon expansion."""
    if formula[0] == "const":
        return formula[1]
    name = min(atoms(formula))
    return satisfiable(simplify(formula, {name: False})) or satisfiable(
        simplify(formula, {name: True})
    )


def guarantees_model_b(formula: Formula) -> bool:
    without_model_b = simplify(formula, {MODEL_B_FLAG: False})
    return not satisfiable(without_model_b)


def unguarded_references(path: Path) -> list[tuple[int, str]]:
    """Return executable references not guaranteed by the active Model B path."""
    source = path.read_text()
    try:
        masked = swift_lexical_mask(source)
    except ValueError as error:
        raise ValueError(f"{path}: {error}") from error

    frames: list[ConditionalFrame] = []
    current = TRUE
    failures: list[tuple[int, str]] = []
    directive_pattern = re.compile(r"\s*#(if|elseif|else|endif)\b\s*(.*)\Z")

    for number, (raw_line, code) in enumerate(zip(source.splitlines(), masked.splitlines()), 1):
        directive = directive_pattern.match(code)
        if directive:
            kind, expression = directive.groups()
            try:
                if kind == "if":
                    condition = parse_condition(expression)
                    frames.append({"outer": current, "seen": condition, "has_else": False})
                    current = combine("and", current, condition)
                elif kind == "elseif":
                    if not frames:
                        raise ValueError("#elseif without matching #if")
                    frame = frames[-1]
                    if frame["has_else"]:
                        raise ValueError("#elseif after #else")
                    condition = parse_condition(expression)
                    current = combine(
                        "and", frame["outer"], combine("and", negate(frame["seen"]), condition)
                    )
                    frame["seen"] = combine("or", frame["seen"], condition)
                elif kind == "else":
                    if expression.strip():
                        raise ValueError("unexpected expression after #else")
                    if not frames:
                        raise ValueError("#else without matching #if")
                    frame = frames[-1]
                    if frame["has_else"]:
                        raise ValueError("duplicate #else")
                    frame["has_else"] = True
                    current = combine("and", frame["outer"], negate(frame["seen"]))
                else:
                    if expression.strip():
                        raise ValueError("unexpected expression after #endif")
                    if not frames:
                        raise ValueError("#endif without matching #if")
                    frame = frames.pop()
                    current = frame["outer"]
            except ValueError as error:
                raise ValueError(f"{path}:{number}: malformed #{kind}: {error}") from error
            continue

        if any(re.search(rf"\b{re.escape(token)}\b", code) for token in MODEL_B_DECLARATIONS):
            if not guarantees_model_b(current):
                failures.append((number, raw_line.strip()))

    if frames:
        raise ValueError(f"{path}: unbalanced conditional compilation: {len(frames)} missing #endif")
    return failures


class ModelBCallerGuardContractTests(unittest.TestCase):
    def references(self, snippet: str) -> list[tuple[int, str]]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Snippet.swift"
            path.write_text(snippet)
            return unguarded_references(path)

    def test_model_b_declaration_references_are_compile_time_guarded(self) -> None:
        failures = {}
        for path in CALLERS:
            references = unguarded_references(path)
            if references:
                failures[str(path.relative_to(ROOT))] = references
        self.assertEqual({}, failures)

    def test_unguarded_executable_reference_is_rejected(self) -> None:
        self.assertEqual([(1, "ModelBRNodeService.shared.start()")],
                         self.references("ModelBRNodeService.shared.start()\n"))

    def test_newly_isolated_native_backend_references_are_rejected(self) -> None:
        snippet = "SwiftRNSBackend()\nNomadNetFetch.fetch()\n"
        self.assertEqual([1, 2], [line for line, _ in self.references(snippet)])

    def test_identifiers_in_normal_and_multiline_strings_are_ignored(self) -> None:
        snippet = 'let normal = "ModelBRNodeService \\\"quoted\\\""\nlet multiline = """\nRNodeSeamConfig\n"""\n'
        self.assertEqual([], self.references(snippet))

    def test_tracked_references_in_string_interpolation_remain_executable(self) -> None:
        ordinary = 'let value = "service: \\(ModelBRNodeService.shared)"\n'
        multiline = 'let value = """\nconfig: \\(RNodeSeamConfig.load())\n"""\n'
        nested = 'let value = "service: \\(decorate((ModelBRNodeService.shared), with: \")"))"\n'
        self.assertEqual([(1, ordinary.strip())], self.references(ordinary))
        self.assertEqual([(2, "config: \\(RNodeSeamConfig.load())")], self.references(multiline))
        self.assertEqual([(1, nested.strip())], self.references(nested))

    def test_tracked_references_in_raw_string_interpolation_remain_executable(self) -> None:
        raw = 'let value = #"config: \\#(RNodeSeamConfig.load())"#\n'
        raw_multiline = 'let value = ##"""\nservice: \\##(ModelBRNodeService.shared)\n"""##\n'
        self.assertEqual([(1, raw.strip())], self.references(raw))
        self.assertEqual([(2, "service: \\##(ModelBRNodeService.shared)")],
                         self.references(raw_multiline))

    def test_tracked_references_in_regex_interpolation_cannot_be_hidden(self) -> None:
        extended = 'let pattern = #/prefix-\\#(RNodeSeamConfig.load())/#\n'
        self.assertEqual([(1, extended.strip())], self.references(extended))
        with self.assertRaisesRegex(ValueError, "tracked declaration"):
            self.references('let pattern = /prefix-\\(ModelBRNodeService.shared)/\n')

    def test_harmless_interpolation_and_escaped_introducers_remain_accepted(self) -> None:
        snippet = '''logger.info("state: \\(state)")
let escaped = "literal: \\\\(ModelBRNodeService.shared)"
let wrongRawDelimiter = ##"literal: \\#(RNodeSeamConfig.load())"##
let literalNames = "ModelBRNodeService RNodeSeamConfig"
let nestedLiteral = "value: \\(decorate("ModelBRNodeService" /* RNodeSeamConfig */))"
'''
        guarded = '''#if COLUMBA_RUNTIME_MODEL_B
let value = "service: \\(ModelBRNodeService.shared)"
#endif
'''
        self.assertEqual([], self.references(snippet))
        self.assertEqual([], self.references(guarded))

    def test_unterminated_interpolation_fails_clearly(self) -> None:
        snippets = (
            'let value = "service: \\(make(ModelBRNodeService.shared)\n',
            'let value = """service: \\(ModelBRNodeService.shared\n',
            'let value = #"service: \\#(ModelBRNodeService.shared\n',
            'let pattern = #/service-\\#(ModelBRNodeService.shared\n',
        )
        for snippet in snippets:
            with self.subTest(snippet=snippet):
                with self.assertRaisesRegex(ValueError, "unterminated Swift interpolation"):
                    self.references(snippet)

    def test_raw_string_closure_exposes_following_executable_reference(self) -> None:
        snippet = 'let text = #"embedded quote: ""#; ModelBRNodeService.shared.start() // "\n'
        self.assertEqual([(1, snippet.strip())], self.references(snippet))

    def test_identifiers_and_ordinary_quotes_inside_raw_strings_are_ignored(self) -> None:
        snippet = '''let normal = ##"ModelBRNodeService " and "" and #" plus \\#(RNodeSeamConfig)"##
let multiline = #"""
RNodeSeamConfig " and """ without the matching hash and \\##(ModelBInboundReplay)
AppGroupRNodeServer // not a comment
"""#
'''
        self.assertEqual([], self.references(snippet))

    def test_unterminated_raw_literals_fail_clearly(self) -> None:
        with self.assertRaisesRegex(ValueError, "unterminated Swift raw string literal"):
            self.references('let value = ##"ModelBRNodeService"#\n')
        with self.assertRaisesRegex(ValueError, "unterminated Swift raw multiline string"):
            self.references('let value = #"""\nRNodeSeamConfig\n"""\n')

    def test_raw_url_and_comment_markers_do_not_affect_lexing(self) -> None:
        snippet = '''let url = #"https://example.test/a/* ModelBRNodeService */"#
// #"RNodeSeamConfig"#
AppGroupRNodeServer.start()
'''
        self.assertEqual([(3, "AppGroupRNodeServer.start()")], self.references(snippet))

    def test_declaration_names_inside_extended_regex_are_ignored(self) -> None:
        extended = 'let pattern = ##/AppGroupRNodeServer / and #/ RNodeSeamConfig/##\n'
        self.assertEqual([], self.references(extended))

    def test_tracked_declaration_inside_ambiguous_bare_regex_fails_clearly(self) -> None:
        with self.assertRaisesRegex(
            ValueError, "ambiguous Swift bare regex contains a tracked declaration"
        ):
            self.references('let pattern = /ModelBRNodeService|RNodeSeamConfig/\n')

    def test_regex_closure_exposes_following_executable_reference(self) -> None:
        extended = 'let pattern = #/https://example.test/ModelBRNodeService/#; RNodeSeamConfig.load()\n'
        bare = 'let pattern = /safe\\/pattern/; AppGroupRNodeServer.start()\n'
        self.assertEqual([(1, extended.strip())], self.references(extended))
        self.assertEqual([(1, bare.strip())], self.references(bare))

    def test_unterminated_extended_regex_fails_clearly(self) -> None:
        with self.assertRaisesRegex(ValueError, "unterminated Swift extended regex literal"):
            self.references('let pattern = ##/ModelBRNodeService/#\n')

    def test_url_string_does_not_hide_following_executable_reference(self) -> None:
        snippet = 'let url = "https://example.test"; ModelBRNodeService.shared.start()\n'
        self.assertEqual([(1, snippet.strip())], self.references(snippet))

    def test_line_block_and_nested_block_comments_are_ignored(self) -> None:
        snippet = """// ModelBRNodeService
/* RNodeSeamConfig */
/* outer AppGroupRNodeServer /* nested ModelBInboundReplay */ still comment */
"""
        self.assertEqual([], self.references(snippet))

    def test_exact_and_conjunctive_guards_are_accepted(self) -> None:
        exact = "#if COLUMBA_RUNTIME_MODEL_B\nModelBRNodeService.shared.start()\n#endif\n"
        compound = "#if (COLUMBA_RUNTIME_MODEL_B && os(iOS))\nRNodeSeamConfig.load()\n#endif\n"
        self.assertEqual([], self.references(exact))
        self.assertEqual([], self.references(compound))

    def test_negated_and_disjunctive_guards_are_rejected(self) -> None:
        negated = "#if !COLUMBA_RUNTIME_MODEL_B\nModelBRNodeService.shared.start()\n#endif\n"
        disjunction = "#if COLUMBA_RUNTIME_MODEL_B || os(iOS)\nRNodeSeamConfig.load()\n#endif\n"
        self.assertEqual(1, len(self.references(negated)))
        self.assertEqual(1, len(self.references(disjunction)))

    def test_many_atom_conjunctive_guard_short_circuits_after_substitution(self) -> None:
        alternatives = " || ".join(f"FEATURE_{index}" for index in range(80))
        snippet = (
            f"#if COLUMBA_RUNTIME_MODEL_B && ({alternatives})\n"
            "ModelBRNodeService.shared.start()\n"
            "#endif\n"
        )
        self.assertEqual([], self.references(snippet))

    def test_logical_implication_handles_nested_negation_and_disjunction(self) -> None:
        implied = """#if COLUMBA_RUNTIME_MODEL_B || (FEATURE_A && !FEATURE_A)
ModelBRNodeService.shared.start()
#endif
"""
        not_implied = """#if (COLUMBA_RUNTIME_MODEL_B && FEATURE_A) || !FEATURE_A
RNodeSeamConfig.load()
#endif
"""
        self.assertEqual([], self.references(implied))
        self.assertEqual([2], [line for line, _ in self.references(not_implied)])

    def test_nested_else_and_elseif_paths_preserve_branch_semantics(self) -> None:
        nested = """#if COLUMBA_RUNTIME_MODEL_B
#if os(iOS)
ModelBRNodeService.shared.start()
#else
RNodeSeamConfig.load()
#endif
#endif
"""
        elseif_else = """#if os(macOS)
ModelBRNodeService.shared.start()
#elseif COLUMBA_RUNTIME_MODEL_B && os(iOS)
RNodeSeamConfig.load()
#else
AppGroupRNodeServer.start()
#endif
"""
        self.assertEqual([], self.references(nested))
        references = self.references(elseif_else)
        self.assertEqual([2, 6], [line for line, _ in references])

    def test_unbalanced_and_malformed_directives_fail_clearly(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing #endif"):
            self.references("#if COLUMBA_RUNTIME_MODEL_B\nModelBRNodeService.shared.start()\n")
        with self.assertRaisesRegex(ValueError, "#else without matching #if"):
            self.references("#else\n")
        with self.assertRaisesRegex(ValueError, "malformed #if"):
            self.references("#if COLUMBA_RUNTIME_MODEL_B &&\n#endif\n")

    def test_propagation_manager_has_no_runtime_model_b_selector(self) -> None:
        source = CALLERS[2].read_text()
        self.assertNotIn("BackendPreference.modelB", source)


if __name__ == "__main__":
    unittest.main()
