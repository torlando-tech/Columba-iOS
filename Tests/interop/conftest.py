"""Pytest fixtures for Columba-iOS interop tests.

Boots the SidebandCore headless peer once per test session (start-up is ~5s
and re-entry takes longer than the rest of the test combined) and exposes
helpers that wrap simctl / xcrun for the iOS simulator under test.

Each test scenario can:

  * `sideband` fixture → live `SidebandPeer` for `.send_text/.send_image/...`
    + `.wait_for_tapped_message(...)` to assert inbound on the peer's side.
  * `sim` fixture → a `Simulator` helper that knows how to read the running
    Columba app's `Documents/diag.log`, fire `lxma://test-send` deep links
    via Maestro, and pull the sim's identity / LXMF delivery destination.

The Sideband peer's identity_hex is the value tests pass as the `to=` arg
on iOS-side sends, and the sim's `lxmf_delivery_hex` is what the peer sends
to in the reverse direction.

Prerequisites (asserted in the session fixture):
  * `rnsd` and `lxmd` running on the host (Mac).
  * An iOS simulator booted with Columba.app installed (see Tests/interop/
    README.md).
  * Sideband checkout at `~/repos/Sideband` (override via `SIDEBAND_SRC`).
  * The pytest venv on `RNS`/`LXMF` — `~/.reticulum-host/venv` works.
"""

from __future__ import annotations
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import pytest

# Make peer_sideband.py importable (it sits next to this conftest).
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

SIDEBAND_SRC = os.environ.get("SIDEBAND_SRC", os.path.expanduser("~/repos/Sideband"))
sys.path.insert(0, SIDEBAND_SRC)

BUNDLE_ID = "network.columba.Columba"
PROP_NODE_HEX = os.environ.get("PROP_NODE_HEX", "")  # e.g. lxmd's hash; auto-detected at session start
LOG_TAIL_LINES = 800  # how much of Documents/diag.log we keep handy per assertion


# ── helpers ──────────────────────────────────────────────────────────────


def _sh(cmd: list[str], *, check: bool = True, timeout: float = 60.0) -> str:
    """Run a subprocess, return stdout as text. Raises on non-zero by default."""
    r = subprocess.run(cmd, check=check, timeout=timeout, capture_output=True, text=True)
    return r.stdout


def _booted_udid() -> str:
    """Return the UDID of the currently booted iPhone simulator. Fails the
    test session if zero or more-than-one is booted."""
    out = _sh(["xcrun", "simctl", "list", "devices", "booted"])
    udids = re.findall(r"\(([0-9A-Fa-f-]{36})\)\s*\(Booted\)", out)
    if not udids:
        pytest.exit("No iOS simulator is booted. `xcrun simctl boot 'iPhone 17'` first.", returncode=2)
    if len(udids) > 1:
        pytest.exit(f"Multiple booted simulators: {udids}. Shut all but one.", returncode=2)
    return udids[0]


def _app_data_container(udid: str) -> Path:
    """The Columba.app's data container (Documents/, Library/, …)."""
    out = _sh(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"])
    return Path(out.strip())


# ── data classes ──────────────────────────────────────────────────────────


@dataclass
class TestSendResult:
    """One outcome from `lxma://test-send`. Parsed from diag.log."""

    sent_hash_hex: Optional[str]   # LXMessage hash from outcome=queued(...)
    method: str                    # opportunistic / direct / propagated as logged
    error: Optional[str]           # python exception or other reason on failure


# ── Simulator wrapper ─────────────────────────────────────────────────────


class Simulator:
    """Thin wrapper around `xcrun simctl` + Maestro for the booted sim
    running Columba. Exposes only what interop tests need: identity
    discovery, deep-link send, diag.log tailing."""

    def __init__(self, udid: str):
        self.udid = udid
        self.container = _app_data_container(udid)
        self.diag_log = self.container / "Documents" / "diag.log"
        if not self.diag_log.exists():
            pytest.exit(
                f"diag.log missing under {self.container}. Is Columba running on the sim?",
                returncode=2,
            )

    # ---- identity / destinations ----

    @property
    def identity_hex(self) -> str:
        """Local RNS identity hash hex (the `[PY] started identity=…` line)."""
        for line in self._tail_diag(LOG_TAIL_LINES * 4):  # search wider
            m = re.search(r"\[PY\] started identity=([0-9a-f]+)\s+destination=", line)
            if m:
                return m.group(1)
        pytest.fail("Couldn't find `[PY] started identity=…` in diag.log")

    @property
    def lxmf_delivery_hex(self) -> str:
        """Local LXMF delivery-destination hash hex (the `destination=…` half)."""
        for line in self._tail_diag(LOG_TAIL_LINES * 4):
            m = re.search(r"\[PY\] started identity=[0-9a-f]+\s+destination=([0-9a-f]+)", line)
            if m:
                return m.group(1)
        pytest.fail("Couldn't find `destination=…` in diag.log")

    # ---- propagation-node helpers ----

    def auto_propagation_node_hex(self) -> Optional[str]:
        """First `lxmf.propagation` announce we've heard whose name is
        non-empty (= a real propagation node, not a malformed announce)."""
        for line in reversed(self._tail_diag(LOG_TAIL_LINES * 4)):
            m = re.search(
                r"\[PY\] announce dest=([0-9a-f]+)\s+aspect=lxmf\.propagation\s+name=\"([^\"]*)\"",
                line,
            )
            if m and m.group(2):  # non-empty name
                return m.group(1)
        return None

    def set_propagation_node(self, node_hex: str, *, wait: float = 5.0) -> None:
        """Wire iOS's LXMRouter to `node_hex` as outbound PN via the
        existing `lxma://test-prop-sync` URL. Idempotent."""
        url = f"lxma://test-prop-sync?node={node_hex}"
        self._open_url(url)
        time.sleep(wait)
        # Surface success/failure via diag.log so callers can fail fast.
        for line in reversed(self._tail_diag(80)):
            if "[TEST-PROP-SYNC] set node" in line:
                return
            if "[TEST-PROP-SYNC] error" in line:
                pytest.fail(f"set_propagation_node({node_hex}) failed: {line.strip()}")
        pytest.fail("set_propagation_node didn't produce a [TEST-PROP-SYNC] log line")

    # ---- send (typed deep-link) ----

    def test_send(
        self,
        *,
        to_hex: str,
        content: str = "",
        method: str = "opportunistic",
        image_bytes: Optional[bytes] = None,
        image_format: Optional[str] = None,
        file_bytes: Optional[bytes] = None,
        file_name: Optional[str] = None,
        wait: float = 30.0,
    ) -> TestSendResult:
        """Drive `lxma://test-send?…` via Maestro (so the iOS "Open in
        Columba?" prompt is dismissed) and block until the next
        [TEST-SEND] outcome lands in diag.log."""
        params = [f"to={to_hex}", f"content={content}", f"method={method}"]
        if image_bytes is not None and image_format:
            params.append(f"image_hex={image_bytes.hex()}")
            params.append(f"image_format={image_format}")
        if file_bytes is not None and file_name:
            params.append(f"file_hex={file_bytes.hex()}")
            params.append(f"file_name={file_name}")
        url = "lxma://test-send?" + "&".join(params)

        # Snapshot file position so we only scan lines written AFTER the
        # send. (Index-based tail slicing was broken in an earlier version:
        # a tail of the last N lines drifts as the file grows, so "lines
        # added after `before`" was always empty when the file already had
        # ≥ N lines.)
        before_size = self.diag_log.stat().st_size if self.diag_log.exists() else 0
        self._open_url(url)

        deadline = time.time() + wait
        while time.time() < deadline:
            new_lines = self._read_diag_since(before_size)
            outcome = self._parse_outcome(new_lines)
            if outcome is not None:
                return outcome
            time.sleep(0.4)
        # On timeout, dump the window for triage so test output explains itself.
        final_lines = self._read_diag_since(before_size)
        print(f"[test_send-timeout] {len(final_lines)} diag.log lines after URL fired:", flush=True)
        for line in final_lines[-30:]:
            print(f"  {line}", flush=True)
        pytest.fail(f"test_send timed out waiting for [TEST-SEND] outcome on {url}")

    def _read_diag_since(self, start_offset: int) -> list[str]:
        """Return the diag.log lines written since `start_offset` bytes."""
        try:
            with open(self.diag_log, "rb") as f:
                f.seek(start_offset)
                data = f.read()
        except FileNotFoundError:
            return []
        return data.decode("utf-8", errors="replace").splitlines()

    @staticmethod
    def _parse_outcome(lines: list[str]) -> Optional[TestSendResult]:
        for line in lines:
            if "[TEST-SEND] outcome=" not in line and "[TEST-SEND] error=" not in line:
                continue
            method_m = re.search(r"method=(\w+)", line)
            method = method_m.group(1) if method_m else "?"
            if "[TEST-SEND] error=" in line:
                err = line.split("[TEST-SEND] error=", 1)[1].strip()
                return TestSendResult(sent_hash_hex=None, method=method, error=err)
            hash_m = re.search(r'messageHash:\s*"([0-9a-f]+)"', line)
            return TestSendResult(
                sent_hash_hex=hash_m.group(1) if hash_m else None,
                method=method,
                error=None,
            )
        return None

    # ---- internals ----

    def _open_url(self, url: str) -> None:
        """Open a custom-scheme URL on the booted sim. iOS pops an
        "Open in Columba?" confirmation the first time per session — we
        dismiss it with Maestro (subsequent calls are silent).

        IMPORTANT: do NOT `launchApp` first — Maestro's launchApp relaunches
        the app, which triggers AppServices.initialize → DiagLog.clear,
        wiping the very log we're about to parse for the [TEST-SEND]
        outcome. The app is already running from the session fixture; just
        dispatching the URL is enough to foreground it through the system
        URL handler."""
        flow = (
            "appId: " + BUNDLE_ID + "\n"
            "---\n"
            f"- openLink: \"{url}\"\n"
            "- tapOn: { text: \"Open\", optional: true }\n"
            "- waitForAnimationToEnd: { timeout: 3000 }\n"
        )
        flow_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"_interop_openlink_{os.getpid()}.yaml"
        flow_path.write_text(flow)
        try:
            _sh(["maestro", "--device", self.udid, "test", str(flow_path)], timeout=90)
        finally:
            flow_path.unlink(missing_ok=True)

    def _tail_diag(self, n: int) -> list[str]:
        """Return the last `n` lines of diag.log. Cheap enough to call per
        poll; the file is rotated only on app restart."""
        try:
            with open(self.diag_log, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            return []
        text = data.decode("utf-8", errors="replace")
        return text.splitlines()[-n:]


# ── pytest fixtures ───────────────────────────────────────────────────────


@pytest.fixture(scope="session")
def sim() -> Simulator:
    """The one booted iPhone simulator with Columba.app installed + running."""
    return Simulator(_booted_udid())


@pytest.fixture(scope="session")
def sideband():
    """SidebandCore headless peer. Boots once per session; tests address it
    via `sideband.identity_hex` and observe inbound via the LXMRouter tap."""
    from peer_sideband import SidebandPeer  # type: ignore

    peer = SidebandPeer(
        sideband_src=SIDEBAND_SRC,
        config_dir=os.path.expanduser("~/.sideband-interop"),
        prop_node_hex=PROP_NODE_HEX or None,
    )
    peer.start(ready_timeout=60.0)
    try:
        yield peer
    finally:
        peer.stop()


@pytest.fixture(scope="session", autouse=True)
def _bootstrap_paths(sim, sideband):
    """Force one Sideband re-announce + give the sim a moment to ingest it,
    so the first test isn't paying for path-table cold-start latency.
    Marked autouse so test files don't have to remember this."""
    print(f"[BOOT] Sideband identity_hex={sideband.identity_hex}", flush=True)
    print(f"[BOOT] iOS sim lxmf_delivery_hex={sim.lxmf_delivery_hex}", flush=True)
    sideband._core.lxmf_destination.announce()
    print("[BOOT] Sideband announce sent — waiting 6s for sim to ingest …", flush=True)
    time.sleep(6.0)
    # Verify the sim heard the Sideband announce, so a wait_for_tapped_message
    # failure later doesn't get blamed on the wrong layer.
    expect = sideband.identity_hex
    for line in reversed(sim._tail_diag(800)):
        if expect in line and "lxmf.delivery" in line:
            print(f"[BOOT] sim heard Sideband: {line.strip()}", flush=True)
            return
    pytest.fail(
        f"Sim never logged an inbound lxmf.delivery announce for {expect}. "
        f"rnsd may not be bridging shared-instance ↔ TCPServer correctly."
    )
