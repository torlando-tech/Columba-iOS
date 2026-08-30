#!/usr/bin/env python3
"""Regression contract: Columba iOS diagnostic logs must never carry
message content.

DiagLog / ExtensionDiagLog write to on-device log files (diag.log,
ext-diag.log) that are extractable via devicectl / Xcode, and BOTH mirrors
every line into the OS unified log (NSLog / os.Logger). Logging message
plaintext (or attachment payload bytes) there defeats the E2E encryption
the app exists to provide. The Network Extension already declares this as
a hard NO-PII contract (see Sources/Shared/ExtensionDiagLog.swift); this
contract extends it to the app-side sinks and pins the specific leaks
fixed by the "no message content in logs" remediation:

  * `handlePythonEvent`'s `.inbound` case logged the full plaintext
    (`content="…"` and `content=\\(content, privacy: .public)`) —
    production path, every received message.
  * DEBUG `test-send` / `test-inbound` deep-link hooks logged the content.
  * The RNode seam wire logged a `RNodeSeamMessage` whose `.send` /
    `.dataReceived` cases embed `Data` frame bytes.
  * MessageBubble logged the raw image-field value (payload bytes).

Run with:
    python3 -B -m unittest Tests.static.test_no_message_content_in_logs
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APPSERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
COLUMBA_APP = ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift"
MESSAGE_BUBBLE = ROOT / "Sources/ColumbaApp/Views/Messaging/MessageBubble.swift"
SEAM_WIRE = ROOT / "Sources/Shared/AppGroupRNodeSeamWire.swift"
RNODE_SEAM = ROOT / "Sources/Shared/RNodeSeam.swift"

# Every .swift file compiled into a shipping target (Sources/ is the
# Xcode-project source root; Tests/, app/ (Python), support/ are excluded).
SWIFT_SOURCES = sorted((ROOT / "Sources").rglob("*.swift"))

# Log sinks that reach disk and/or the unified log, matched against the
# code outside string literals. All receiver-UNRESTRICTED so that any
# receiver spelling the project uses — `logger`, `self.log`, `sLogger`,
# `backgroundPropagationLogger`, a future `netLogger`, … — is covered:
#   * `DiagLog.log(…)` / `ExtensionDiagLog.log(…)` — any `.log(` call
#     (the static diag sinks);
#   * `<receiver>.<level>(…)` where level ∈ debug/info/notice/warning/
#     error/trace/fatal — os.Logger style calls (`logger.info(…)` etc.);
#   * bare diagnostic helpers spelled `<Name>_status(…)` (`DiagLog_status`)
#     and `NSLog(…)` (unified log direct);
#   * optional log callbacks `log?(…)` / `self?.log?(…)` (the seam-server
#     `((String) -> Void)?` properties that forward to the host's DiagLog).
SINK_RE = re.compile(
    r"\.log\("
    r"|\b[A-Za-z_][A-Za-z0-9_]*\.(?:debug|info|notice|warning|error|trace|fatal)\("
    r"|\b[A-Z][A-Za-z0-9_]*_status\("
    r"|\bNSLog\("
    r"|(?<![A-Za-z0-9_])log\?\("
)

# Interpolations that carry message-content variables. Matched against the
# FIRST token of each `\(` interpolation so `messageHash` / `contentLength`
# are NOT flagged (boundary-aware).
CONTENT_TOKENS = {
    "content", "contentString", "plaintext", "messageContent", "body",
    "payload", "rawData", "frameData", "title",
    # `raw` — the Python status-JSON string; a `.prefix(n)` of it lands
    # payload data in diag.log / the unified log (`.count` is metadata).
    "raw",
    # RNodeSeamMessage interpolated whole carries .send(data:)/.dataReceived
    # frame bytes in its default description.
    "message",
}


def _first_token(inner: str) -> str | None:
    """The leading identifier of a Swift expression, if any.

    `content` -> `content`; `content.utf8.count` -> `content`;
    `String(describing: rawField)` -> `String`; `("foo")` -> None.
    """
    m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", inner)
    return m.group(1) if m else None


def _iter_log_calls(text: str) -> list[tuple[int, int, str]]:
    """Return (start, end, argtext) for every log-sink call in `text`.

    The scan is string-aware: characters inside single- or triple-quoted
    string literals (and Swift interpolation expressions, which are code,
    not string data) are never treated as call syntax, so a string literal
    that merely *mentions* `logger.info(` can never mask or fake a real
    sink. Calls are extracted over the full file text, so multiline
    invocations (`DiagLog.log(\n    "…")`) are captured exactly like
    single-line ones.
    """
    n = len(text)
    calls: list[tuple[int, int, str]] = []
    i = 0
    in_line_comment = False
    in_block_comment = 0
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment -= 1
                i += 2
                continue
            if ch == "/" and nxt == "*":
                in_block_comment += 1
                i += 2
                continue
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = 1
            i += 2
            continue
        if ch == '"':
            if text.startswith('"""', i):
                end = text.find('"""', i + 3)
                i = n if end < 0 else end + 3
                continue
            i += 1
            while i < n:
                c2 = text[i]
                if c2 == "\\":
                    i += 2
                    continue
                if c2 == '"':
                    i += 1
                    break
                i += 1
            continue
        m = SINK_RE.match(text, i)
        if m:
            start, end, argtext = _extract_balanced_args(text, m.end() - 1)
            if end >= 0 and argtext is not None:
                calls.append((start, end, argtext))
        i += 1
    return calls


def _extract_balanced_args(text: str, open_paren: int):
    """From `text[open_paren] == "("`, return (start, end, argtext) where
    end is one past the matching `)` and argtext is the interior (string-
    and comment-aware, so a `)` inside a literal or comment never
    terminates the call). Returns (open_paren, -1, None) if unbalanced."""
    n = len(text)
    depth = 0
    i = open_paren
    in_line_comment = False
    in_block_comment = 0
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment -= 1
                i += 2
                continue
            if ch == "/" and nxt == "*":
                in_block_comment += 1
                i += 2
                continue
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = 1
            i += 2
            continue
        if ch == '"':
            if text.startswith('"""', i):
                end = text.find('"""', i + 3)
                i = n if end < 0 else end + 3
                continue
            i += 1
            while i < n:
                c2 = text[i]
                if c2 == "\\":
                    i += 2
                    continue
                if c2 == '"':
                    i += 1
                    break
                i += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return open_paren, i + 1, text[open_paren + 1:i]
        i += 1
    return open_paren, -1, None


def _interpolations(arg: str) -> list[str]:
    # Scan only the string-literal text for `\(` escapes and capture each
    # interpolation (nested-paren aware) INCLUDING its leading backslash,
    # so detection sees the real Swift escape and nothing else. A simple
    # scan keeps this dependency-free.
    out: list[str] = []
    in_str = False
    i = 0
    while i < len(arg):
        ch = arg[i]
        if in_str:
            if ch == "\\":
                if i + 1 < len(arg):
                    esc = arg[i + 1]
                    if esc == "(":
                        # Swift interpolation; capture the full escape
                        # (nested-paren aware), leading backslash included
                        depth = 1
                        j = i + 2
                        while j < len(arg) and depth:
                            if arg[j] == "(":
                                depth += 1
                            elif arg[j] == ")":
                                depth -= 1
                            j += 1
                        out.append(arg[i:j])
                        i = j
                        continue
                    else:
                        # an escaped character (\\, \", \n, …) — the pair
                        # is literal text, never an interpolation
                        i += 2
                        continue
                else:
                    i += 1
                continue
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        i += 1
    return out


def _enclosing_scope_declares_string(text: str, expr_index: int, token: str) -> bool:
    """True when a declaration of `token` typed as `String` is in scope at
    `expr_index`.

    `message` is a generic name: the only content-bearing `message` in this
    codebase is `RNodeSeamMessage`, but plain `String` error/status
    parameters named `message` (e.g. `setConnectionError(_ message: String)`,
    and the sinks' own `log(_ message: String)` line-formatting bodies) are
    not message content. Scan the text backwards from the expression,
    string- and comment-aware, tracking brace/paren depth so only
    declarations from the expression's own scope or an enclosing scope
    count (an inner `let message: String` declared *after* the expression
    must not apply)."""
    n = len(text)
    brace_depth = 0
    in_line_comment = False
    in_block_comment = 0
    i = expr_index
    while i > 0:
        i -= 1
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment -= 1
                continue
            if ch == "/" and nxt == "*":
                in_block_comment += 1
                continue
            continue
        if ch == "/" and nxt == "/":
            in_line_comment = True
            i -= 1
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = 1
            i -= 1
            continue
        if ch == '"':
            if text[i:i + 3] == '"""':
                j = text.rfind('"""', 0, i)
                i = j if j >= 0 else -1
                continue
            j = i - 1
            while j >= 0:
                c2 = text[j]
                if c2 == "\\":
                    j -= 2
                    continue
                if c2 == '"':
                    break
                j -= 1
            i = j
            continue
        # Paren depth is intentionally NOT tracked: the expression sits
        # inside call parens, and backwards past them we must reach the
        # enclosing signature's parameter list (`func f(_ message: String)`
        # is inside its own `(...)`) to see the declaration.
        if ch == "}":
            brace_depth += 1
        elif ch == "{":
            brace_depth -= 1
            if brace_depth < 0:
                return False  # left the enclosing function scope
        else:
            if brace_depth == 0:
                m = re.search(
                    re.escape(token) + r"\s*:\s*String\b",
                    text[max(0, i - 200):i + 1],
                )
                if m:
                    return True
    return False


def _content_bearing_interpolations(
    arg: str,
    file_text: str | None = None,
    call_index: int = 0,
) -> list[str]:
    """Interpolations in `arg` whose value is a message-content variable.

    `arg` is the argument text of one call site in `file_text` starting at
    `call_index` (used for the in-scope-type check below); pass None for
    synthetic snippets. Entries from _interpolations() are the full escape
    including the leading backslash, e.g. `\\(content)`. Flags:
      * `\\(content)` / `\\(body)` / … (bare content vars and their property
        chains, e.g. `\\(content.utf8.count)` is ALLOWED — byte counts are
        metadata);
      * `\\(String(describing: rawField)…)`-style dumps of field payloads;
      * `\\(message)` when `message` is not a `String` in scope (a bare
        `RNodeSeamMessage` interpolates its `.send(data:)` frame bytes in
        its default description). `\\(message.diagnosticLabel)` is always
        ALLOWED — test 3 pins that property as metadata-only.
    """
    flagged: list[str] = []
    for interp in _interpolations(arg):
        # Entries are full escapes, e.g. `\\(content)` /
        # `\\(String(describing: x))`. The leading `\\(` is the
        # interpolation delimiter; the expression follows it.
        inner = interp[2:] if interp.startswith("\\(") else interp
        token = _first_token(inner)
        if token is None:
            continue
        if token == "message":
            rest = inner[len(token):].lstrip()
            if rest.startswith(".diagnosticLabel"):
                # Metadata-only seam label (pinned by test 3).
                continue
            # Bare `message` / other chains: flag unless the in-scope
            # declaration is a String (error/status text, the sinks' own
            # `log(_ message: String)` line-formatting bodies).
            if file_text is None:
                # Synthetic snippet without file context: fail closed.
                flagged.append(interp)
            elif not _enclosing_scope_declares_string(file_text, call_index, token):
                flagged.append(interp)
            continue
        if token in CONTENT_TOKENS:
            # Allow byte-count / length derivations (metadata, not content).
            rest = inner[len(token):].lstrip()
            if rest.startswith((".utf8.count", ".count", ".isEmpty")):
                continue
            flagged.append(interp)
        if "String(describing:" in inner and token == "String":
            # `\\(String(describing: rawField).prefix(200))` — the value is a
            # raw field payload.
            m = re.search(r"String\(describing:\s*([A-Za-z_][A-Za-z0-9_.]*)\)", inner)
            if m:
                target = m.group(1).split(".")[-1]
                if target in {"rawField", "rawData", "frameData", "payload", "content", "body"}:
                    if interp not in flagged:
                        flagged.append(interp)
    return flagged


class NoMessageContentInLogsTests(unittest.TestCase):
    # ── 1. The production inbound line: metadata only ──────────────────

    def test_inbound_handler_logs_metadata_only(self) -> None:
        source = APPSERVICES.read_text(encoding="utf-8")
        case = re.search(
            r"case \.inbound\(let sourceHash, let messageHash, let content, let title, "
            r"let fieldsPacked, let method, let rssi, let snr, let t\):\n"
            r"(?P<body>.*?)\n            guard let data = Data\(hexString: sourceHash\)",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(case, "handlePythonEvent `.inbound` case not found")
        assert case is not None
        body = case.group("body")
        log_line = re.search(r'DiagLog\.log\("(?:[^"\\]|\\.)*"\)', body)
        self.assertIsNotNone(log_line, "`.inbound` case no longer has its diag line")
        assert log_line is not None
        line = log_line.group(0)
        # No content / title / full hashes in the line.
        self.assertNotIn("content=\\\"", line)
        self.assertNotIn("\\(content)", line)
        self.assertNotIn("\\(title)", line)
        self.assertNotIn("source=\\(sourceHash)", line)  # must be prefixed
        self.assertNotIn("message=\\(messageHash)", line)  # must be prefixed
        # Metadata correlation fields remain.
        self.assertIn("source=\\(sourceHash.prefix(8))", line)
        self.assertIn("message=\\(messageHash.prefix(8))", line)
        self.assertIn("len=\\(content.utf8.count)", line)

    # ── 2. DEBUG deep-link hooks: no content ───────────────────────────

    def test_debug_test_hooks_log_no_content(self) -> None:
        source = COLUMBA_APP.read_text(encoding="utf-8")
        self.assertNotIn('content=\\\"\\(content)', source)
        self.assertNotIn("content=\\(content, privacy: .public)", source)
        self.assertNotIn("\\(content)", source.replace("\\(content.utf8.count", ""))

    # ── 3. RNode seam: whole-message interpolation is gone ────────────

    def test_seam_wire_never_dumps_message_bytes(self) -> None:
        seam = SEAM_WIRE.read_text(encoding="utf-8")
        self.assertNotIn("dropped \\(message)", seam)
        self.assertIn("diagnosticLabel", seam)
        model = RNODE_SEAM.read_text(encoding="utf-8")
        # The label must exist and must NOT interpolate the Data payloads.
        label = re.search(
            r"var diagnosticLabel: String \{(?P<body>.*?)\n    \}", model, re.DOTALL
        )
        self.assertIsNotNone(label, "RNodeSeamMessage.diagnosticLabel missing")
        assert label is not None
        self.assertNotIn("\\(data)", label.group("body"))
        self.assertNotIn("\\(reqId, data)", label.group("body"))
        self.assertIn("data.count", label.group("body"))

    # ── 4. MessageBubble: no raw image-field dump ─────────────────────

    def test_message_bubble_never_logs_field_payload(self) -> None:
        source = MESSAGE_BUBBLE.read_text(encoding="utf-8")
        self.assertNotIn(
            'value=\\(String(describing: rawField)', source,
            "MessageBubble still dumps the raw image-field value",
        )

    # ── 5. Repo-wide sweep: no content-bearing log interpolations ─────
    #    Multiline-call- and receiver-agnostic by construction (see
    #    _iter_log_calls / SINK_RE above).

    def test_no_content_bearing_log_interpolations_anywhere(self) -> None:
        offenders: list[str] = []
        for path in SWIFT_SOURCES:
            rel = path.relative_to(ROOT).as_posix()
            text = path.read_text(encoding="utf-8")
            for start, _end, arg in _iter_log_calls(text):
                lineno = text.count("\n", 0, start) + 1
                for bad in _content_bearing_interpolations(
                    arg, file_text=text, call_index=start
                ):
                    offenders.append(f"{rel}:{lineno}: {bad.strip()}")
        self.assertEqual(
            offenders,
            [],
            "log sinks still carry message-content interpolations:\n"
            + "\n".join(offenders),
        )

    # ── 6. The sweep itself must see what it claims to see ────────────
    #    Pins the scanner against the two blind classes this contract was
    #    written to close: multiline invocations and non-`logger`
    #    receiver spellings. If a refactor makes _iter_log_calls miss
    #    these, the contract silently weakens — these cases stop it.

    def test_sweep_catches_multiline_and_unusual_receivers(self) -> None:
        # NOTE: each fixture is a literal Swift source snippet; the file's
        # `\\(` is ONE backslash in the Swift text (a real interpolation).
        multiline = (
            '        DiagLog.log(\n'
            '            "inbound content=\\(content) seen"\n'
            '        )\n'
        )
        found = [a for _s, _e, a in _iter_log_calls(multiline)]
        self.assertEqual(len(found), 1, "multiline DiagLog.log call not captured")
        self.assertEqual(
            _content_bearing_interpolations(found[0]),
            ["\\(content)"],
            "multiline content interpolation not flagged",
        )

        unusual = '        sLogger.info("body arrived: \\(body) end")\n'
        found = [a for _s, _e, a in _iter_log_calls(unusual)]
        self.assertEqual(len(found), 1, "sLogger.info call not captured")
        self.assertEqual(
            _content_bearing_interpolations(found[0]),
            ["\\(body)"],
            "unusual-receiver content interpolation not flagged",
        )

        bg = '    backgroundPropagationLogger.error(\n' \
             '        "sync failed content=\\(content)"\n' \
             '    )\n'
        found = [a for _s, _e, a in _iter_log_calls(bg)]
        self.assertEqual(len(found), 1, "backgroundPropagationLogger call not captured")
        self.assertEqual(
            _content_bearing_interpolations(found[0]),
            ["\\(content)"],
        )

        # A string literal that merely mentions a sink must not create a
        # (fake) call nor mask a real one.
        decoy = (
            '    let hint = "remember to call logger.info(x)"\n'
            '    self.log.warning("title=\\(title)")\n'
        )
        found = [a for _s, _e, a in _iter_log_calls(decoy)]
        self.assertEqual(len(found), 1, "string-mentioned sink misparsed as a call")
        self.assertEqual(_content_bearing_interpolations(found[0]), ["\\(title)"])

        # `message` is type-dependent: a bare non-String `message`
        # (RNodeSeamMessage: its default description embeds frame bytes)
        # must be flagged; a `String` named `message` in scope is not.
        seam = (
            '    public func send(_ message: RNodeSeamMessage) {\n'
            '        guard false else {\n'
            '            ExtensionDiagLog.log("dropped \\(message)")\n'
            '            return\n'
            '        }\n'
            '    }\n'
        )
        for _s, _e, a in _iter_log_calls(seam):
            self.assertEqual(
                _content_bearing_interpolations(a, file_text=seam, call_index=_s),
                ["\\(message)"],
                "bare RNodeSeamMessage interpolation not flagged",
            )

        seam_label = (
            '    public func send(_ message: RNodeSeamMessage) {\n'
            '        ExtensionDiagLog.log("dropped \\(message.diagnosticLabel)")\n'
            '    }\n'
        )
        for _s, _e, a in _iter_log_calls(seam_label):
            self.assertEqual(
                _content_bearing_interpolations(a, file_text=seam_label, call_index=_s),
                [],
                "diagnosticLabel (metadata) wrongly flagged",
            )

        string_msg = (
            '    func setConnectionError(_ message: String) {\n'
            '        logger.warning("Connection error: \\(message)")\n'
            '    }\n'
        )
        for _s, _e, a in _iter_log_calls(string_msg):
            self.assertEqual(
                _content_bearing_interpolations(a, file_text=string_msg, call_index=_s),
                [],
                "String-named `message` wrongly flagged as content",
            )

        # Metadata-only interpolations stay allowed (no false positives).
        ok = '    logger.info("inbound len=\\(content.utf8.count) fields=\\(fields.count)")\n'
        found = [a for _s, _e, a in _iter_log_calls(ok)]
        self.assertEqual(len(found), 1)
        self.assertEqual(_content_bearing_interpolations(found[0]), [])

        # Bare diagnostic helpers, the unified-log direct sink, and the
        # optional seam-server log callback must all be captured.
        bare = (
            '        guard let raw else { return nil }\n'
            '        DiagLog_status("decode failed: \\(error) raw=\\(raw.prefix(200))")\n'
        )
        found = [a for _s, _e, a in _iter_log_calls(bare)]
        self.assertEqual(len(found), 1, "DiagLog_status(…) call not captured")
        self.assertEqual(
            _content_bearing_interpolations(found[0]),
            ["\\(raw.prefix(200))"],
            "raw payload prefix not flagged",
        )

        callback = '        self?.log?("[RNODE] server: failed content=\\(content)")\n'
        found = [a for _s, _e, a in _iter_log_calls(callback)]
        self.assertEqual(len(found), 1, "log?(…) callback not captured")
        self.assertEqual(
            _content_bearing_interpolations(found[0]),
            ["\\(content)"],
            "optional-callback content interpolation not flagged",
        )

        nslog = '        NSLog("%@", "[STATUS] payload=\\(payload)")\n'
        found = [a for _s, _e, a in _iter_log_calls(nslog)]
        self.assertEqual(len(found), 1, "NSLog(…) call not captured")
        self.assertEqual(
            _content_bearing_interpolations(found[0]),
            ["\\(payload)"],
            "NSLog content interpolation not flagged",
        )


if __name__ == "__main__":
    unittest.main()
