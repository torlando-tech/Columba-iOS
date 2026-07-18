#!/usr/bin/env python3
"""Static compile-region contract for declarations absent from the Python target."""

from pathlib import Path
import itertools
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
    """Blank Swift comments and strings while preserving newlines and offsets."""
    output = list(source)
    index = 0
    block_depth = 0
    state = "code"

    def blank(position: int) -> None:
        if output[position] not in "\r\n":
            output[position] = " "

    while index < len(source):
        if block_depth:
            if source.startswith("/*", index):
                blank(index)
                blank(index + 1)
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                blank(index)
                blank(index + 1)
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
            blank(index)
            if source[index] in "\r\n":
                raise ValueError("unterminated Swift string literal before newline")
            if source[index] == "\\" and index + 1 < len(source):
                blank(index + 1)
                index += 2
            elif source[index] == '"':
                state = "code"
                index += 1
            else:
                index += 1
            continue

        if state == "multiline_string":
            if source[index] == "\\" and index + 1 < len(source):
                blank(index)
                blank(index + 1)
                index += 2
            elif source.startswith('"""', index):
                for offset in range(3):
                    blank(index + offset)
                index += 3
                state = "code"
            else:
                blank(index)
                index += 1
            continue

        if source.startswith("//", index):
            blank(index)
            blank(index + 1)
            index += 2
            state = "line_comment"
        elif source.startswith("/*", index):
            blank(index)
            blank(index + 1)
            index += 2
            block_depth = 1
        elif source.startswith('"""', index):
            for offset in range(3):
                blank(index + offset)
            index += 3
            state = "multiline_string"
        elif source[index] == '"':
            blank(index)
            index += 1
            state = "string"
        else:
            index += 1

    if block_depth:
        raise ValueError("unterminated Swift block comment")
    if state == "multiline_string":
        raise ValueError("unterminated Swift multiline string")
    if state == "string":
        raise ValueError("unterminated Swift string literal")
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


def evaluate(formula: Formula, values: dict[str, bool]) -> bool:
    kind = formula[0]
    if kind == "const":
        return formula[1]
    if kind == "atom":
        return values[formula[1]]
    if kind == "not":
        return not evaluate(formula[1], values)
    if kind == "and":
        return evaluate(formula[1], values) and evaluate(formula[2], values)
    if kind == "or":
        return evaluate(formula[1], values) or evaluate(formula[2], values)
    raise AssertionError(f"unknown formula node {kind}")


def guarantees_model_b(formula: Formula) -> bool:
    names = sorted(atoms(formula) | {MODEL_B_FLAG})
    for bits in itertools.product((False, True), repeat=len(names)):
        values = dict(zip(names, bits))
        if evaluate(formula, values) and not values[MODEL_B_FLAG]:
            return False
    return True


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

    def test_identifiers_in_normal_and_multiline_strings_are_ignored(self) -> None:
        snippet = 'let normal = "ModelBRNodeService \\\"quoted\\\""\nlet multiline = """\nRNodeSeamConfig\n"""\n'
        self.assertEqual([], self.references(snippet))

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
