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
    (`content="…"`) — production path, every received message.
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

# Log sinks that reach disk and/or the unified log.
DIAG_SINK_RE = re.compile(
    r"(?:DiagLog|ExtensionDiagLog)\.log\((?P<arg>.*?)\)\s*$"
)
# os.Logger calls: `logger.info("…")`, `log.debug("…")`, etc. (the os.log
# interpolations are what land in the unified log; `privacy: .public`
# interpolations are what a log-archive reader can extract).
OSLOG_CALL_RE = re.compile(
    r"\blogger\.(?:debug|info|notice|warning|error|trace)\("
    r"|\bself\.log\.(?:debug|info|notice|warning|error|trace)\("
    r"|\blog\.(?:debug|info|notice|warning|error|trace)\("
)

# Interpolations that carry message-content variables. Matched against the
# FIRST token of each `\(…)` interpolation so `messageHash` / `contentLength`
# are NOT flagged (boundary-aware).
CONTENT_TOKENS = {
    "content", "contentString", "plaintext", "messageContent", "body",
    "payload", "rawData", "frameData", "title",
    # RNodeSeamMessage interpolated whole carries .send(data:)/.dataReceived
    # frame bytes in its default description.
    "message",
}
INTERPOLATION_RE = re.compile(r"\\\(.*?\)")
FIRST_TOKEN_RE = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)")


def _first_token(interp: str) -> str | None:
    """The leading identifier of an interpolation, if any.

    `\\(content)` -> `content`; `\\(content.utf8.count)` -> `content`;
    `\\(self.message.content)` -> `self` (caller-qualified; handled by the
    qualified checks); `\\("foo")` -> None.
    """
    m = FIRST_TOKEN_RE.match(interp)
    return m.group(1) if m else None


def _diagnostic_args(line: str) -> list[str]:
    """Balanced-paren extraction of the argument text of each log call in
    `line` (handles nested `\\(a.isEmpty ? 0 : b)` interpolation parens)."""
    args: list[str] = []
    for sink in list(DIAG_SINK_RE.finditer(line)) + list(OSLOG_CALL_RE.finditer(line)):
        start = sink.end()  # position just after the opening "("
        depth = 1
        i = start
        in_str = False
        while i < len(line) and depth:
            ch = line[i]
            if in_str:
                if ch == "\\":
                    i += 1
                elif ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            i += 1
        if depth == 0:
            args.append(line[start:i - 1])
    return args


def _interpolations(arg: str) -> list[str]:
    # Strip string-literal text so interpolation detection only sees real
    # Swift interpolation escapes. A simple scan keeps this dependency-free.
    out: list[str] = []
    in_str = False
    i = 0
    while i < len(arg):
        ch = arg[i]
        if in_str:
            if ch == "\\":
                if i + 1 < len(arg) and arg[i + 1] == "(":
                    # capture the interpolation (nested-paren aware)
                    depth = 1
                    j = i + 2
                    s = i + 1
                    while j < len(arg) and depth:
                        if arg[j] == "(":
                            depth += 1
                        elif arg[j] == ")":
                            depth -= 1
                        j += 1
                    out.append(arg[s:j])
                    i = j
                    continue
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        i += 1
    return out


def _content_bearing_interpolations(arg: str) -> list[str]:
    """Interpolations in `arg` whose value is a message-content variable.

    Flags:
      * `\\(content)` / `\\(body)` / … (bare content vars and their property
        chains, e.g. `\\(content.utf8.count)` is ALLOWED — byte counts are
        metadata; so the rule only fires on the bare variable or a direct
        `String(describing: <content var>)` dump);
      * `\\(String(describing: rawField)…)`-style dumps of field payloads;
      * `\\(message)` where `message` is an RNodeSeamMessage (frame bytes).
    """
    flagged: list[str] = []
    for interp in _interpolations(arg):
        token = _first_token(interp)
        if token is None:
            continue
        if token in CONTENT_TOKENS:
            # Allow byte-count / length derivations (metadata, not content).
            rest = interp[len(token):].lstrip()
            if rest.startswith((".utf8.count", ".count", ".isEmpty")):
                continue
            flagged.append(interp)
        elif "String(describing:" in interp and token == "":
            # `\\(String(describing: rawField).prefix(200))` — the value is a
            # raw field payload; the leading token is `String`.
            m = re.search(r"String\(describing:\s*([A-Za-z_][A-Za-z0-9_.]*)\)", interp)
            if m:
                target = m.group(1).split(".")[-1]
                if target in {"rawField", "rawData", "frameData", "payload", "content", "body"}:
                    flagged.append(interp)
        if "String(describing:" in interp and token == "String":
            m = re.search(r"String\(describing:\s*([A-Za-z_][A-Za-z0-9_.]*)\)", interp)
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
            r"let fieldsPacked, let method, let t\):\n"
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

    def test_no_content_bearing_log_interpolations_anywhere(self) -> None:
        offenders: list[str] = []
        for path in SWIFT_SOURCES:
            rel = path.relative_to(ROOT).as_posix()
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                # Skip pure comment lines.
                stripped = line.lstrip()
                if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*"):
                    continue
                for arg in _diagnostic_args(line):
                    for bad in _content_bearing_interpolations(arg):
                        offenders.append(f"{rel}:{lineno}: {bad.strip()}")
        self.assertEqual(
            offenders,
            [],
            "log sinks still carry message-content interpolations:\n"
            + "\n".join(offenders),
        )


if __name__ == "__main__":
    unittest.main()
