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
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import pytest

# Make peer_sideband.py importable (it sits next to this conftest).
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

SIDEBAND_SRC = os.environ.get("SIDEBAND_SRC", os.path.expanduser("~/repos/Sideband"))
sys.path.insert(0, SIDEBAND_SRC)

BUNDLE_ID = "network.columba.Columba"
APP_GROUP_ID = "group.network.columba.Columba"  # InterfaceRepository's UserDefaults suite
PROP_NODE_HEX = os.environ.get("PROP_NODE_HEX", "")  # e.g. lxmd's hash; auto-detected at session start
LOG_TAIL_LINES = 800  # how much of Documents/diag.log we keep handy per assertion

# The host rnsd/lxmd shared instance the interop sim bridges through. The suite
# seeds a TCP-client interface to this into Columba's interface store at session
# start (see _ensure_rnsd_interface), so a fresh install / clean sim needs no
# manual Settings → Network Interfaces → Add step. Override for a non-default host.
RNSD_TCP_HOST = os.environ.get("RNSD_TCP_HOST", "127.0.0.1")
RNSD_TCP_PORT = int(os.environ.get("RNSD_TCP_PORT", "4242"))

# lxmd binary — used to read the propagation-node hash (--status) and to force
# a propagation announce during bootstrap (so the propagated test runs instead
# of skipping on lxmd's 5-min announce cadence). Override with LXMD_BIN.
LXMD_BIN = (os.environ.get("LXMD_BIN") or shutil.which("lxmd")
            or os.path.expanduser("~/.reticulum-host/venv/bin/lxmd"))


# ── helpers ──────────────────────────────────────────────────────────────


def _sh(cmd: list[str], *, check: bool = True, timeout: float = 60.0) -> str:
    """Run a subprocess, return stdout as text. Raises on non-zero by default."""
    r = subprocess.run(cmd, check=check, timeout=timeout, capture_output=True, text=True)
    return r.stdout


def _yaml_escape(s: str) -> str:
    """Escape a string for safe use inside a double-quoted YAML scalar.
    Maestro reads the flow file line-by-line as YAML, so backslashes, quotes,
    or control characters in user content would break the matcher silently —
    a newline in particular splits the scalar into two YAML entries. Tests
    typically use safe ASCII timestamps so this rarely fires — defensive.
    Backslash is escaped first so the sequences we introduce below aren't
    double-escaped."""
    return (
        s.replace("\\", "\\")
         .replace("\"", "\"")
         .replace("\n", "\\n")
         .replace("\r", "\\r")
         .replace("\t", "\\t")
         .replace("\0", "\\0")
    )


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


def _app_group_prefs_plist(udid: str) -> Optional[Path]:
    """The app-group UserDefaults plist where InterfaceRepository persists once
    the app-group suite has been created. None on a fresh sim that hasn't
    written it yet (the app falls back to / migrates from .standard)."""
    base = (Path.home() / "Library/Developer/CoreSimulator/Devices" / udid
            / "data/Containers/Shared/AppGroup")
    for p in base.glob(f"*/Library/Preferences/{APP_GROUP_ID}.plist"):
        return p
    return None


def _ensure_rnsd_interface(udid: str) -> None:
    """Make the suite self-contained: seed Columba's interface store with a
    single TCP-client interface to the host rnsd/lxmd shared instance
    (RNSD_TCP_HOST:RNSD_TCP_PORT) so the sim bridges to the Sideband peer —
    no manual "Add Interface" step on a fresh install / clean sim.

    InterfaceRepository persists interfaces as a JSON blob under
    `com.columba.interfaces` in UserDefaults (app-group suite, falling back to
    / migrated from .standard). We write the blob straight into the container
    plist(s): `simctl spawn defaults` targets the booted-user GLOBAL domain,
    NOT the sandbox/app-group plist the app actually reads. Then bounce cfprefsd
    so the relaunched app re-reads our edit instead of flushing a stale copy
    back. Deterministic + idempotent — the store is set to exactly this one
    interface (a dedicated interop sim wants nothing else)."""
    entity = [{
        "id": "interop-rnsd-tcp", "name": "rnsd-interop", "type": "TCPClient",
        "enabled": True, "mode": "full",
        "config": {"type": "tcpClient",
                   "config": {"targetHost": RNSD_TCP_HOST, "targetPort": RNSD_TCP_PORT}},
        "displayOrder": 0, "createdAt": 0, "updatedAt": 0,
    }]
    blob = json.dumps(entity).encode("utf-8")

    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], capture_output=True)

    # Write to the standard sandbox plist AND the app-group plist if it exists.
    # First run: only standard exists → the app's migrateFromStandardDefaults
    # copies it into the app-group suite on launch. Later runs: app-group is
    # authoritative (migration is skipped once it has the key), so we must set
    # it directly too.
    targets = [_app_data_container(udid) / "Library/Preferences" / f"{BUNDLE_ID}.plist"]
    ag = _app_group_prefs_plist(udid)
    if ag is not None:
        targets.append(ag)
    for plist_path in targets:
        try:
            with open(plist_path, "rb") as f:
                pl = plistlib.load(f)
        except Exception:
            pl = {}
        pl["com.columba.interfaces"] = blob   # bytes -> <data>, exactly UserDefaults.set(Data)
        plist_path.parent.mkdir(parents=True, exist_ok=True)
        with open(plist_path, "wb") as f:
            plistlib.dump(pl, f, fmt=plistlib.FMT_BINARY)

    # cfprefsd caches container prefs; kick it AFTER editing so it re-reads our
    # file rather than serving / flushing back the stale in-memory copy
    # (mirrors clean_location_state's dance). user/501 is the sim's only scope.
    subprocess.run(["xcrun", "simctl", "spawn", udid, "launchctl", "kickstart", "-k",
                    "user/501/com.apple.cfprefsd.xpc.daemon"], capture_output=True)
    time.sleep(0.5)
    subprocess.run(["xcrun", "simctl", "launch", udid, BUNDLE_ID], check=True, capture_output=True)

    # Confirm the backend loaded the interface (config written with N>=1), so a
    # silent seed failure surfaces here rather than as a confusing path-bootstrap
    # timeout. diag.log is cleared on launch, so the match is fresh.
    diag = _app_data_container(udid) / "Documents" / "diag.log"
    deadline = time.time() + 45.0
    while time.time() < deadline:
        try:
            text = diag.read_text(errors="replace")
        except FileNotFoundError:
            text = ""
        if re.search(r"\[RNS\] wrote config \(\d+ bytes, ([1-9]\d*) interfaces\)", text):
            return
        time.sleep(0.5)
    pytest.fail(
        f"Columba did not register the rnsd TCP interface "
        f"({RNSD_TCP_HOST}:{RNSD_TCP_PORT}) within 45 s of relaunch — the interface "
        f"seed did not take (check the sandbox/app-group prefs plist)."
    )


def _lxmd_propagation_hex() -> Optional[str]:
    """Query the running lxmd for its LXMF propagation-node destination hash
    (the `--status` line `Propagation Node running on <hash>`). None if lxmd is
    down / unreachable."""
    try:
        out = _sh([LXMD_BIN, "--status", "--timeout", "10"], check=False, timeout=20)
    except Exception:
        return None
    m = re.search(r"Propagation Node running on <([0-9a-f]+)>", out)
    return m.group(1) if m else None


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
        # Identity & lxmf_delivery hex are persistent across relaunches —
        # cache the first successful read so a Maestro `launchApp` later
        # (which clears diag.log via AppServices.initialize → DiagLog.clear)
        # doesn't strand later property reads on a freshly-empty log.
        # The propagation-node hex shares the same problem with extra
        # urgency: lxmd announces every 5 minutes (announce_interval) so
        # the per-launch log slice almost never carries a fresh sighting
        # by the time `test_image_ios_to_sideband_propagated` runs.
        self._cached_identity_hex: Optional[str] = None
        self._cached_lxmf_delivery_hex: Optional[str] = None
        self._cached_propagation_node_hex: Optional[str] = None

    # ---- identity / destinations ----

    @property
    def identity_hex(self) -> str:
        """Local RNS identity hash hex (the `[RNS] started identity=…` line)."""
        if self._cached_identity_hex is None:
            self._wait_for_started_destinations()
        assert self._cached_identity_hex is not None
        return self._cached_identity_hex

    @property
    def lxmf_delivery_hex(self) -> str:
        """Local LXMF delivery-destination hash hex (the `destination=…` half)."""
        if self._cached_lxmf_delivery_hex is None:
            self._wait_for_started_destinations()
        assert self._cached_lxmf_delivery_hex is not None
        return self._cached_lxmf_delivery_hex

    def _wait_for_started_destinations(self, timeout: float = 30.0) -> None:
        """Wait for async backend startup instead of racing the first config log line."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for line in reversed(self._tail_diag(LOG_TAIL_LINES * 4)):
                match = re.search(
                    r"\[RNS\] started identity=([0-9a-f]+)\s+destination=([0-9a-f]+)",
                    line,
                )
                if match:
                    self._cached_identity_hex = match.group(1)
                    self._cached_lxmf_delivery_hex = match.group(2)
                    return
            time.sleep(0.25)
        pytest.fail("Couldn't find `[RNS] started identity=… destination=…` in diag.log")

    # ---- propagation-node helpers ----

    def auto_propagation_node_hex(self) -> Optional[str]:
        """First `lxmf.propagation` announce we've heard whose name is
        non-empty (= a real propagation node, not a malformed announce).

        Three resolution tiers, in order: cached value from an earlier
        sighting; the `PROP_NODE_HEX` env var (already wired into the
        Sideband peer above); diag.log scan. The env-var tier skips the
        announce-window race entirely — lxmd's default
        `announce_interval = 5` (minutes) is long enough that the
        per-launch diag.log slice rarely catches one before this method
        is called."""
        if self._cached_propagation_node_hex is not None:
            return self._cached_propagation_node_hex
        if PROP_NODE_HEX:
            self._cached_propagation_node_hex = PROP_NODE_HEX
            return self._cached_propagation_node_hex
        for line in reversed(self._tail_diag(LOG_TAIL_LINES * 4)):
            m = re.search(
                r"\[RNS\] announce dest=([0-9a-f]+)\s+aspect=lxmf\.propagation\s+name=\"([^\"]*)\"",
                line,
            )
            if m and m.group(2):  # non-empty name
                self._cached_propagation_node_hex = m.group(1)
                return self._cached_propagation_node_hex
        return None

    def set_propagation_node(self, node_hex: str, *, wait: float = 5.0) -> None:
        """Wire iOS's LXMRouter to `node_hex` as outbound PN via the
        existing `lxma://test-prop-sync` URL. Idempotent."""
        url = f"lxma://test-prop-sync?node={node_hex}"
        # Poll diag.log (like test_send / test_send_telemetry) rather than a flat
        # sleep: return as soon as the outcome lands and surface an immediate
        # URL-handler error instead of always burning the full `wait`.
        before_size = self.diag_log.stat().st_size if self.diag_log.exists() else 0
        self._open_url(url)
        deadline = time.time() + wait
        while time.time() < deadline:
            for line in reversed(self._read_diag_since(before_size)):
                if "[TEST-PROP-SYNC] set node" in line:
                    return
                if "[TEST-PROP-SYNC] error" in line:
                    pytest.fail(f"set_propagation_node({node_hex}) failed: {line.strip()}")
            time.sleep(0.4)
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
        # Percent-encode the free-text params (content / image_format / file_name)
        # so a value with & = # or spaces can't split the query string or corrupt
        # a key/value slot on the iOS handler side. to_hex / *_hex are hex and
        # method is a fixed enum, so they're already URL-safe.
        params = [f"to={to_hex}", f"content={quote(content, safe='')}", f"method={method}"]
        if image_bytes is not None and image_format:
            params.append(f"image_hex={image_bytes.hex()}")
            params.append(f"image_format={quote(image_format, safe='')}")
        if file_bytes is not None and file_name:
            params.append(f"file_hex={file_bytes.hex()}")
            params.append(f"file_name={quote(file_name, safe='')}")
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

    def test_send_telemetry(
        self,
        *,
        to_hex: str,
        packed: Optional[bytes] = None,
        custom_meta: Optional[bytes] = None,
        cease: bool = False,
        wait: float = 30.0,
    ) -> str:
        """Drive `lxma://test-telemetry` so iOS calls `backend.telemetry.*`
        directly (the path the still-compile-gated LocationSharingManager
        would otherwise drive). Returns the [TEST-TELEMETRY] outcome line
        from diag.log so callers can assert what happened iOS-side."""
        if cease:
            url = f"lxma://test-telemetry?to={to_hex}&cease=1"
        else:
            if packed is None:
                raise ValueError("test_send_telemetry requires packed= (or cease=True)")
            params = [f"to={to_hex}", f"packed_hex={packed.hex()}"]
            if custom_meta is not None:
                params.append(f"meta_hex={custom_meta.hex()}")
            url = "lxma://test-telemetry?" + "&".join(params)

        before_size = self.diag_log.stat().st_size if self.diag_log.exists() else 0
        self._open_url(url)
        deadline = time.time() + wait
        while time.time() < deadline:
            for line in self._read_diag_since(before_size):
                if "[TEST-TELEMETRY] send outcome=" in line or \
                   "[TEST-TELEMETRY] cease outcome=" in line or \
                   "[TEST-TELEMETRY] error=" in line or \
                   "[TEST-TELEMETRY] packed_hex missing" in line or \
                   "[TEST-TELEMETRY] no backend" in line:
                    return line.strip()
            time.sleep(0.4)
        pytest.fail(f"test_send_telemetry timed out on {url}")

    def _read_diag_since(self, start_offset: int) -> list[str]:
        """Return the diag.log lines written since `start_offset` bytes."""
        try:
            with open(self.diag_log, "rb") as f:
                f.seek(start_offset)
                data = f.read()
        except FileNotFoundError:
            return []
        return data.decode("utf-8", errors="replace").splitlines()

    # ---- UI assertions (Maestro) ----

    def assert_bubble_visible(
        self,
        *,
        peer_display_name: str = "Anonymous Peer",
        content: Optional[str] = None,
        has_image: bool = False,
        has_file_name: Optional[str] = None,
        timeout: float = 30.0,
    ) -> None:
        """Navigate Chats → tap the peer's conversation row → assert the
        bubble's children are visible.

        Pins the *render* half of the inbound path: a bubble with an empty
        content, no image, and no file would still be persisted (and would
        let the diag.log `[RNS] inbound` proxy assertion pass), but this
        catches a regression in `MessageBubble.init(from record:)` /
        `LxmfFieldCodec.unpack(...)` / the SwiftUI rendering of attachment
        payloads.

        Requires the iOS Columba build to carry `.accessibilityIdentifier`
        on the image (`bubble_image`) and file chip (`bubble_file_chip`)
        — added in MessageBubble.swift for exactly this assertion.
        """
        # The flow stays inline because Maestro flows can't take params for
        # `assertVisible` matchers; each test renders its own.
        # `appId` + `launchApp:false` skips relaunch (DiagLog.clear() would
        # otherwise wipe diag.log mid-test — see _open_url's notes).
        lines = [
            "appId: " + BUNDLE_ID,
            "---",
            # Stale notification-permission alert blocks the Chats tap.
            # First-launch only, so optional.
            "- tapOn: { text: \"Allow\", optional: true }",
            "- tapOn: { text: \"Don't Allow\", optional: true }",
            "- waitForAnimationToEnd: { timeout: 1500 }",
            "- back",
            "- waitForAnimationToEnd: { timeout: 800 }",
            "- back",
            "- waitForAnimationToEnd: { timeout: 800 }",
            "- tapOn:",
            "    text: \"Chats\"",
            "    optional: true",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            f"- tapOn: \"{_yaml_escape(content or peer_display_name)}\"",
            "- waitForAnimationToEnd: { timeout: 2500 }",
        ]
        if content is not None:
            lines += [
                "- assertVisible:",
                f"    text: \"{_yaml_escape(content)}\"",
            ]
        if has_image:
            lines += [
                "- assertVisible:",
                "    id: \"bubble_image\"",
            ]
        if has_file_name is not None:
            lines += [
                "- assertVisible:",
                f"    text: \"{_yaml_escape(has_file_name)}\"",
            ]
        flow_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"_interop_assert_{os.getpid()}.yaml"
        flow_path.write_text("\n".join(lines) + "\n")
        try:
            # Long Maestro timeout so a slow inbound delivery doesn't
            # surface as a Maestro CLI timeout instead of our assertion
            # error (which carries more info).
            _sh(["maestro", "--device", self.udid, "test", str(flow_path)], timeout=timeout + 30)
        except subprocess.CalledProcessError as e:
            pytest.fail(
                f"assert_bubble_visible failed (peer={peer_display_name!r}, "
                f"content={content!r}, has_image={has_image}, "
                f"has_file_name={has_file_name!r}). Maestro stderr:\n"
                f"{e.stderr or e.stdout}"
            )
        finally:
            flow_path.unlink(missing_ok=True)

    def assert_attachment_preview_and_export(
        self,
        *,
        image: bool = False,
        file_name: Optional[str] = None,
        file_index: int = 0,
        expected_preview_text: Optional[str] = None,
        expected_bytes: Optional[bytes] = None,
        timeout: float = 30.0,
    ) -> None:
        """Tap the rendered attachment and complete the native Quick Look save action."""
        if image == (file_name is not None):
            raise ValueError("select exactly one attachment kind")
        lines = ["appId: " + BUNDLE_ID, "---"]
        if image:
            lines += [
                "- tapOn:",
                "    id: \"bubble_image\"",
                "    index: 1",
                "    optional: true",
                "- tapOn:",
                "    id: \"bubble_image\"",
                "    index: 0",
                "    optional: true",
            ]
            export_action = "Save Image"
        else:
            # The filename is unique to this delivered message. Index scopes
            # duplicate names within that message without colliding with old
            # retained bubbles that carry the same indexed control ID.
            lines += [
                "- tapOn:",
                f"    text: \"{_yaml_escape(file_name or '')}\"",
                f"    index: {file_index}",
            ]
            export_action = "Save to Files"
        lines += ["- waitForAnimationToEnd: { timeout: 2000 }"]
        if expected_preview_text is not None:
            lines += [f"- assertVisible: \"{_yaml_escape(expected_preview_text)}\""]
        if image:
            # Image Quick Look starts with its chrome hidden after the opening
            # animation, so reveal the native controls before sharing.
            lines += [
                "- tapOn: { point: \"50%,50%\" }",
                "- waitForAnimationToEnd: { timeout: 1000 }",
            ]
        lines += [
            # Quick Look's native share button is the lower-right circular
            # control. iOS 26 does not expose its label through the Maestro
            # accessibility hierarchy, so target the system-owned control by
            # its stable location and prove the resulting named save action.
            "- tapOn: { point: \"88%,94%\" }",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            f"- assertVisible: \"{export_action}\"",
            f"- tapOn: \"{export_action}\"",
            "- waitForAnimationToEnd: { timeout: 2000 }",
        ]
        if image:
            lines += [
                "- tapOn: { text: \"Allow Full Access\", optional: true }",
                "- tapOn: { text: \"Allow\", optional: true }",
                "- waitForAnimationToEnd: { timeout: 1000 }",
            ]
        elif expected_preview_text is not None:
            # iOS 26 Simulator returns directly to Quick Look after accepting
            # Save to Files, without exposing a second picker-level Save button.
            lines += [f"- assertVisible: \"{_yaml_escape(expected_preview_text)}\""]
        flow_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"_interop_preview_{os.getpid()}.yaml"
        close_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"_interop_preview_close_{os.getpid()}.yaml"
        flow_path.write_text("\n".join(lines) + "\n")
        close_path.write_text("\n".join([
            "appId: " + BUNDLE_ID,
            "---",
            "- tapOn: { point: \"91%,9%\" }",
            "- waitForAnimationToEnd: { timeout: 1000 }",
        ]) + "\n")
        started_at = time.time()
        try:
            _sh(["maestro", "--device", self.udid, "test", str(flow_path)], timeout=timeout + 30)
            if expected_bytes is not None:
                tmp_root = _app_data_container(self.udid) / "tmp"
                matches = [
                    item for item in tmp_root.glob("*/*")
                    if item.is_file()
                    and item.stat().st_mtime >= started_at - 1
                    and item.read_bytes() == expected_bytes
                ]
                if not matches:
                    pytest.fail("active Quick Look export did not match source attachment bytes")
            _sh(["maestro", "--device", self.udid, "test", str(close_path)], timeout=timeout + 30)
        except subprocess.CalledProcessError as e:
            details = "\n".join(part for part in (e.stdout, e.stderr) if part)
            pytest.fail(
                f"attachment preview/export failed (image={image}, file_name={file_name!r}). "
                f"Maestro output:\n{details}"
            )
        finally:
            flow_path.unlink(missing_ok=True)
            close_path.unlink(missing_ok=True)

    def assert_bubble_visible_via_network(
        self,
        *,
        peer_display_name: str = "Anonymous Peer",
        content: Optional[str] = None,
        has_image: bool = False,
        has_file_name: Optional[str] = None,
        screenshot: Optional[str] = None,
        timeout: float = 30.0,
    ) -> None:
        """Open the peer's thread via the **Contacts → Network** nav path and
        assert the bubble renders — the BUG #1 path.

        The Chats path (`assert_bubble_visible`) reaches `MessagingView` from
        an existing `Conversation` DB row via a `NavigationLink`. This path
        instead goes Contacts tab → segmented **Network** → tap the peer's
        announce row → NodeDetails → **Start Chat**, which builds a *fresh*
        `Conversation(destinationHash: contact.identityHash, …)` and pushes it
        through the `.chat` `navigationDestination`. `contact.identityHash` is
        the announce's *destination* hash (`Contact.init(from: PathEntry)` sets
        `identityHash = entry.destinationHash`), which equals the inbound
        message's `sourceHash` — so both paths key `loadMessages` on the same
        conversation hash and should render identically. This pins that they
        do (BUG #1 = thread empty via Network tab).

        Leaves the app at the Network-tab root (two trailing `back`s pop
        MessagingView → NodeDetails → Network list) so a follow-on
        `assert_bubble_visible` (Chats path) can still reach the tab bar.
        Call this BEFORE the Chats-path assertion for that reason.
        """
        lines = [
            "appId: " + BUNDLE_ID,
            "---",
            # First-launch permission alerts can block the first tab tap.
            "- tapOn: { text: \"Allow\", optional: true }",
            "- tapOn: { text: \"Don't Allow\", optional: true }",
            "- waitForAnimationToEnd: { timeout: 1500 }",
            # Defensive pop-to-root: if a prior step left the app inside a
            # pushed view (a thread / NodeDetails), the tab bar is hidden and
            # the tab taps below would miss. `back` is a harmless no-op swipe
            # at a tab root, so this is safe when already there.
            "- back",
            "- waitForAnimationToEnd: { timeout: 800 }",
            "- back",
            "- waitForAnimationToEnd: { timeout: 800 }",
            # Contacts tab → segmented "Network" (label renders "Network (N)";
            # Maestro substring-matches "Network").
            "- tapOn:",
            "    text: \"Contacts\"",
            "    optional: true",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            # The segmented control renders "Network (N)". Maestro's text
            # matcher is a FULL-string regex match (not substring), so a bare
            # "Network" misses "Network (15)" — the trailing `.*` is required.
            # Non-optional so a selector regression fails loudly here rather
            # than silently scrolling the wrong (My Contacts) list below.
            "- tapOn:",
            "    text: \"Network.*\"",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            # The announce list can be long (every heard peer/relay/site);
            # scroll the peer's row into view, then open it.
            "- scrollUntilVisible:",
            "    element:",
            f"      text: \"{_yaml_escape(peer_display_name)}\"",
            "    direction: DOWN",
            "    timeout: 15000",
            f"- tapOn: \"{_yaml_escape(peer_display_name)}\"",
            "- waitForAnimationToEnd: { timeout: 2500 }",
            # NodeDetails → Start Chat → MessagingView (.chat destination).
            "- tapOn:",
            "    text: \"Start Chat\"",
            "- waitForAnimationToEnd: { timeout: 2500 }",
        ]
        if content is not None:
            lines += [
                "- assertVisible:",
                f"    text: \"{_yaml_escape(content)}\"",
            ]
        if has_image:
            lines += [
                "- assertVisible:",
                "    id: \"bubble_image\"",
            ]
        if has_file_name is not None:
            lines += [
                "- assertVisible:",
                f"    text: \"{_yaml_escape(has_file_name)}\"",
            ]
        if screenshot is not None:
            lines += [f"- takeScreenshot: {screenshot}"]
        # Pop back to the Network-tab root so the tab bar is reachable again.
        lines += [
            "- back",
            "- waitForAnimationToEnd: { timeout: 1500 }",
            "- back",
            "- waitForAnimationToEnd: { timeout: 1500 }",
        ]
        flow_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"_interop_assert_net_{os.getpid()}.yaml"
        flow_path.write_text("\n".join(lines) + "\n")
        try:
            _sh(["maestro", "--device", self.udid, "test", str(flow_path)], timeout=timeout + 30)
        except subprocess.CalledProcessError as e:
            pytest.fail(
                f"assert_bubble_visible_via_network failed (peer={peer_display_name!r}, "
                f"content={content!r}, has_image={has_image}, "
                f"has_file_name={has_file_name!r}). This is the BUG #1 path "
                f"(thread empty when opened via Contacts→Network). Maestro stderr:\n"
                f"{e.stderr or e.stdout}"
            )
        finally:
            flow_path.unlink(missing_ok=True)

    def assert_peer_pin_visible(self, *, timeout: float = 40.0) -> None:
        """Navigate to the Map tab and assert a peer location pin rendered.

        Pins the inbound-telemetry → map path for the Sideband→iOS
        direction: `IncomingMessageHandler` decodes `FIELD_TELEMETRY` →
        `LocationSharingManager.handleIncomingTelemetry` populates
        `peerLocations` → `MapView` shows the `map_peer_count` badge and
        `MapLibreMapView` draws the marker. `extendedWaitUntil` polls so
        the async LXMF delivery doesn't surface as a flake, then a
        screenshot captures the rendered marker.

        Asserts *pin presence* via the pure-SwiftUI `map_peer_count`
        badge. The MapLibre marker itself is drawn on a GL surface and
        isn't in the accessibility tree, so the marker's icon/colour are
        asserted separately off the `[LOC-RECV]` diag line (see
        `test_location_sideband_to_ios`); the screenshot is the visual
        record of the glyph.
        """
        wait_ms = int(timeout * 1000)
        lines = [
            "appId: " + BUNDLE_ID,
            "---",
            # Warm-foreground: bring Columba to the front WITHOUT restarting
            # it. `peerLocations` lives only in memory, so a cold relaunch
            # (the default `launchApp`, or `simctl launch` after terminate)
            # would empty it and also fire AppServices.initialize →
            # DiagLog.clear, wiping the [LOC-RECV] line. `stopApp: false`
            # just activates the already-running process — verified to leave
            # the [RNS] started count and diag.log untouched. The app can end
            # up backgrounded after the bootstrap fixture's `simctl openurl`
            # announces, so don't assume it's already frontmost.
            "- launchApp: { stopApp: false }",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            "- tapOn: { text: \"Allow\", optional: true }",
            "- tapOn: { text: \"Don't Allow\", optional: true }",
            "- waitForAnimationToEnd: { timeout: 1500 }",
            "- tapOn:",
            "    text: \"Map\"",
            "    optional: true",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            # Poll until the inbound telemetry lands and the peer-count
            # badge renders.
            "- extendedWaitUntil:",
            "    visible:",
            "      id: \"map_peer_count\"",
            f"    timeout: {wait_ms}",
            "- takeScreenshot: { path: screenshots/loc-map }",
        ]
        flow_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"_interop_map_{os.getpid()}.yaml"
        flow_path.write_text("\n".join(lines) + "\n")
        try:
            _sh(["maestro", "--device", self.udid, "test", str(flow_path)], timeout=timeout + 30)
        except subprocess.CalledProcessError as e:
            pytest.fail(
                f"assert_peer_pin_visible failed. Maestro stderr:\n"
                f"{e.stderr or e.stdout}"
            )
        finally:
            flow_path.unlink(missing_ok=True)

    # ---- tappable peer pin (#179) --------------------------------------

    @staticmethod
    def _map_tab_foreground_lines(*, center_on_user: bool = True) -> list[str]:
        """Warm-foreground + Map-tab navigation preamble shared by the
        peer-sheet flows. `stopApp: false` keeps `peerLocations` (in-memory)
        intact — a cold relaunch would empty it. Same pattern as
        `assert_peer_pin_visible`.

        When `center_on_user` is set (the default for the pin-tap flows),
        tap `map_center_on_user` so the camera lands on the simulated fix
        — which the test sets to the peer's own coordinate — guaranteeing
        the pin is on-screen and therefore addressable by Maestro. Without
        this the map center is wherever a prior test / first-fix left it
        and an off-screen GL annotation is culled out of the a11y tree."""
        lines = [
            "appId: " + BUNDLE_ID,
            "---",
            "- launchApp: { stopApp: false }",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            "- tapOn: { text: \"Allow\", optional: true }",
            "- tapOn: { text: \"Don't Allow\", optional: true }",
            "- waitForAnimationToEnd: { timeout: 1500 }",
            "- tapOn:",
            "    text: \"Map\"",
            "    optional: true",
            "- waitForAnimationToEnd: { timeout: 2000 }",
        ]
        if center_on_user:
            lines += [
                "- tapOn: { id: \"map_center_on_user\", optional: true }",
                "- waitForAnimationToEnd: { timeout: 2500 }",
            ]
        return lines

    def _run_maestro_flow(self, lines: list[str], tag: str, *, timeout: float = 60.0) -> None:
        flow_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"_interop_{tag}_{os.getpid()}.yaml"
        flow_path.write_text("\n".join(lines) + "\n")
        try:
            _sh(["maestro", "--device", self.udid, "test", str(flow_path)], timeout=timeout + 30)
        except subprocess.CalledProcessError as e:
            pytest.fail(
                f"Maestro flow {tag!r} failed. stderr:\n{e.stderr or e.stdout}"
            )
        finally:
            flow_path.unlink(missing_ok=True)

    def assert_peer_sheet_open(self, *, pin_id: str, timeout: float = 40.0) -> None:
        """Tap the peer pin (a11y id `peer_pin_<hex>`) and assert the
        `PeerContactSheet` presents with its `peer_sheet_name` element.

        Pins the tap → sheet path end-to-end: `MLNAnnotationView`
        (accessibility element) → `mapView(_:didSelectAnnotation:)` →
        `onPeerTapped` → `selectedPeerHash` → sheet. The `extendedWaitUntil`
        on the pin covers the async GL annotation build after the inbound
        telemetry decodes."""
        wait_ms = int(timeout * 1000)
        lines = self._map_tab_foreground_lines()
        lines += [
            "- extendedWaitUntil:",
            "    visible:",
            f"      id: \"{pin_id}\"",
            f"    timeout: {wait_ms}",
            "- tapOn:",
            f"      id: \"{pin_id}\"",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            "- extendedWaitUntil:",
            "    visible:",
            "      id: \"peer_sheet_name\"",
            f"    timeout: {wait_ms}",
            "- takeScreenshot: { path: screenshots/peer-sheet }",
        ]
        self._run_maestro_flow(lines, "peer_sheet", timeout=timeout)

    def assert_peer_sheet_message_opens_conversation(
        self, *, pin_id: str, timeout: float = 40.0
    ) -> None:
        """Tap the pin, tap the sheet's Message button, and assert the
        peer's conversation opened (the `message_composer` input bar is the
        stable a11y landmark on the messaging screen).

        Pins the cross-tab route: `onOpenPeerChat` → MainTabView switches to
        the Chats tab and holds `pendingPeerChat` → `consumePeerChatRoute`
        resolves the conversation (creating the row for a telemetry-only
        peer) and pushes it via `notificationConversation`."""
        wait_ms = int(timeout * 1000)
        lines = self._map_tab_foreground_lines()
        lines += [
            "- extendedWaitUntil:",
            "    visible:",
            f"      id: \"{pin_id}\"",
            f"    timeout: {wait_ms}",
            "- tapOn:",
            f"      id: \"{pin_id}\"",
            "- extendedWaitUntil:",
            "    visible:",
            "      id: \"peer_sheet_message\"",
            f"    timeout: {wait_ms}",
            "- takeScreenshot: { path: screenshots/peer-sheet-message }",
            "- tapOn:",
            "      id: \"peer_sheet_message\"",
            "- waitForAnimationToEnd: { timeout: 3000 }",
            "- extendedWaitUntil:",
            "    visible:",
            "      id: \"message_composer\"",
            f"    timeout: {wait_ms}",
            "- takeScreenshot: { path: screenshots/peer-sheet-conversation }",
        ]
        self._run_maestro_flow(lines, "peer_sheet_message", timeout=timeout)

    def assert_stale_peer_sheet_removes_pin(
        self, *, pin_id: str, timeout: float = 40.0
    ) -> None:
        """Tap a stale peer's pin, assert the `peer_sheet_remove` action is
        present (stale-only, Android parity), tap it, and assert that
        specific pin disappears from the map.

        Pins the removal path: `onRemove` →
        `LocationSharingManager.removePeerLocation` → `peerLocations`
        drops the entry → the GL annotation is removed and the sheet
        auto-dismisses (its derived peer goes nil). A backdated frame makes
        the pin stale without waiting out the 5-minute freshness window.

        The assertion is on the *specific* `peer_pin_<hex>` element going
        away (not the `map_peer_count` badge) because the session-scoped
        Sideband peer can accumulate alongside earlier tests' pins, so the
        badge count is order-dependent while the individual pin is not."""
        wait_ms = int(timeout * 1000)
        lines = self._map_tab_foreground_lines()
        lines += [
            "- extendedWaitUntil:",
            "    visible:",
            f'      id: "{pin_id}"',
            f"    timeout: {wait_ms}",
            "- tapOn:",
            f'      id: "{pin_id}"',
            "- extendedWaitUntil:",
            "    visible:",
            '      id: "peer_sheet_remove"',
            f"    timeout: {wait_ms}",
            "- takeScreenshot: { path: screenshots/peer-sheet-stale }",
            "- tapOn:",
            '      id: "peer_sheet_remove"',
            "- waitForAnimationToEnd: { timeout: 2000 }",
            "- extendedWaitUntil:",
            "    gone:",
            f'      id: "{pin_id}"',
            f"    timeout: {wait_ms}",
            "- takeScreenshot: { path: screenshots/peer-sheet-removed }",
        ]
        self._run_maestro_flow(lines, "peer_sheet_remove", timeout=timeout)

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
def _ensure_sim_interface(sim):
    """Seed the sim's TCP-client interface to the host rnsd/lxmd shared instance
    before anything else, so the regression suite is fully self-contained (no
    manual 'Add Interface' setup on a clean sim). _bootstrap_paths depends on
    this so it always runs first and the relaunched app is bridged in."""
    _ensure_rnsd_interface(sim.udid)


@pytest.fixture(scope="session", autouse=True)
def _bootstrap_paths(sim, sideband, _ensure_sim_interface):
    """Cold-start the bidirectional path table before the first test.

    Each direction needs the *other side* to know our identity:
      * iOS → Sideband sends: iOS must have heard Sideband's announce
        (so RNS.Identity.recall(sideband_hex) succeeds in
        rns_bridge.send_opportunistic).
      * Sideband → iOS sends: Sideband must have heard iOS's announce
        (so SidebandCore.send_message can `RNS.Identity.recall(ios_hex)`).

    Both halves are required before the first test; otherwise a
    just-reinstalled sim hits "requesting-path" / send_image returns False.
    Marked autouse so test files don't have to remember this."""
    import RNS  # type: ignore — sideband side; we hit RNS directly here
    print(f"[BOOT] Sideband identity_hex={sideband.identity_hex}", flush=True)
    print(f"[BOOT] iOS sim lxmf_delivery_hex={sim.lxmf_delivery_hex}", flush=True)

    # Sideband → iOS: kick announces on both sides, wait for the path to
    # show up on each. We poll AND periodically re-announce because the
    # first announce from a just-booted SidebandCore can race RNS finishing
    # its shared-instance handshake with rnsd, and a just-installed sim's
    # rnsd-side queue isn't yet routing for that destination either.
    sim_hex = sim.lxmf_delivery_hex
    ios_dest = bytes.fromhex(sim_hex)

    deadline = time.time() + 45.0
    sim_seen_sideband = False
    sideband_seen_sim = False
    last_announce = 0.0
    while time.time() < deadline and not (sim_seen_sideband and sideband_seen_sim):
        # Re-announce roughly every 6 s. Cheap on the wire (one packet per
        # side) and gets us out of "announce raced the transport coming up"
        # without exposing a fixed sleep + brittle 3-s wait.
        if time.time() - last_announce > 6.0:
            sideband._core.lxmf_destination.announce()
            sim._open_url("lxma://test-announce?name=interop-test-sim")
            last_announce = time.time()
        # sim → sideband path: sim's diag.log shows the Sideband announce.
        if not sim_seen_sideband:
            for line in reversed(sim._tail_diag(800)):
                if sideband.identity_hex in line and "lxmf.delivery" in line:
                    sim_seen_sideband = True
                    print(f"[BOOT] sim heard Sideband: {line.strip()}", flush=True)
                    break
        # sideband → sim path: Sideband can recall the iOS identity.
        if not sideband_seen_sim:
            ident = RNS.Identity.recall(ios_dest)
            if ident is not None:
                sideband_seen_sim = True
                print(f"[BOOT] Sideband recalled iOS identity for {sim_hex[:12]}…",
                      flush=True)
        time.sleep(0.5)

    if not sim_seen_sideband:
        pytest.fail(
            f"Sim never logged an inbound lxmf.delivery announce for "
            f"{sideband.identity_hex}. rnsd may not be bridging "
            f"shared-instance ↔ TCPServer correctly."
        )
    if not sideband_seen_sim:
        pytest.fail(
            f"Sideband couldn't recall the iOS sim's identity "
            f"({sim_hex}). The sim may not be auto-announcing, or its "
            f"announce isn't reaching rnsd's shared-instance side."
        )

    # Make lxmd's propagation node deterministically known to the sim now that
    # sim + Sideband are connected, so test_image_…_propagated runs instead of
    # skipping on lxmd's 5-min announce cadence (the ordering flake).
    #
    # We can't force a true lxmd broadcast announce non-disruptively: lxmd has
    # no announce trigger (CLI/signal), and RNS.Transport.request_path here is a
    # no-op because this shared-instance process already holds the path so no
    # request leaves the host. A real re-announce needs an lxmd restart, which
    # would drop every mesh device (incl. the physical phones) — wrong for a
    # regression run. Instead discover lxmd's prop-node hash from `--status` and
    # inject it into the sim helper's cache, so auto_propagation_node_hex
    # resolves it. The propagated test still exercises the real delivery path
    # (sim → lxmd message store → Sideband sync); only the announce-discovery
    # hop is shortcut. Warn (don't fail) if lxmd is unreachable.
    prop_hex = PROP_NODE_HEX or _lxmd_propagation_hex()
    if prop_hex:
        sim._cached_propagation_node_hex = prop_hex
        print(f"[BOOT] propagation node pinned to {prop_hex[:12]}… (via lxmd --status)",
              flush=True)
    else:
        print("[BOOT] WARNING: lxmd propagation hash unavailable (lxmd down?); "
              "propagated test will skip.", flush=True)


@pytest.fixture
def clean_location_state(sim):
    """Reset Columba's location-sharing state before the test runs.

    `LocationSharingManager` persists `activePeers` to `UserDefaults` so
    a relaunch resumes sharing; without a reset, a test that drives the
    chat-screen location toggle finds it already *on* from a prior test
    that left state behind, and the first tap turns it OFF instead of
    opening `LocationShareSheet`.

    The reset dance: terminate Columba → `defaults delete
    locationSharing_activePeers` → relaunch → wait for the app to come
    up. Function-scoped and opt-in — the URL-bypass telemetry tests
    (`test_send_telemetry` path) and the attachment round-trips don't
    touch `activePeers` and shouldn't pay the ~8 s relaunch cost.

    Closes the suite-order flake in
    `test_chat_toggle_starts_periodic_sharing`. Any future test that
    drives the chat-screen location toggle UI should request this too.

    NOTE: relaunch also re-triggers `AppServices.initialize → DiagLog.clear`,
    so anything earlier in the session that depends on the pre-relaunch
    diag.log contents must have already cached its reads. `identity_hex`
    and `lxmf_delivery_hex` on `Simulator` already do; new properties
    that read diag.log should follow the same cache pattern.
    """
    subprocess.run(
        ["xcrun", "simctl", "terminate", sim.udid, BUNDLE_ID],
        capture_output=True,
    )
    # `LocationSharingManager` persists `activePeers` to
    # `UserDefaults.standard`, which on the simulator is the APP SANDBOX
    # CONTAINER plist:
    #   <data_container>/Library/Preferences/<bundle>.plist
    # NOT the booted-user global defaults domain that
    # `xcrun simctl spawn <udid> defaults <bundle>` reads/writes. An
    # earlier version of this reset deleted the key via `simctl spawn
    # defaults delete` and "verified" with `defaults read` — but that
    # domain never holds the key, so the delete was a silent no-op and
    # the read always reported "does not exist" (a false success). The
    # app kept loading the stale `activePeers` set from the container
    # plist, leaving the chat toggle ON on ~50% of runs (the flake
    # tracked whatever the previous test happened to leave behind, not
    # any cfprefsd cache). Operate on the container plist directly.
    data_dir = subprocess.run(
        ["xcrun", "simctl", "get_app_container", sim.udid, BUNDLE_ID, "data"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    container_plist = os.path.join(
        data_dir, "Library", "Preferences", f"{BUNDLE_ID}.plist"
    )
    # `plutil -remove` exits non-zero when the key is already absent —
    # harmless, so don't check=True. The relaunched app then reads the
    # key as nil and comes up with activePeers empty.
    subprocess.run(
        ["plutil", "-remove", "locationSharing_activePeers", container_plist],
        capture_output=True,
    )
    # cfprefsd (the sim's user/501 daemon) may still hold the container's
    # preferences cached from the just-terminated app process. Kick it
    # AFTER editing the file on disk so it re-reads our edited plist
    # rather than serving — or flushing back — the stale in-memory copy
    # to the relaunched app. `killall` doesn't exist in the simulator
    # userspace (it silently no-ops); `launchctl kickstart -k` is the
    # working equivalent. user/501 is the only cfprefsd scope in the sim;
    # the warning about preferred service-target syntax is harmless.
    subprocess.run(
        ["xcrun", "simctl", "spawn", sim.udid, "launchctl", "kickstart",
         "-k", "user/501/com.apple.cfprefsd.xpc.daemon"],
        capture_output=True,
    )
    # cfprefsd respawns under launchd within ~100ms; give it a beat
    # before the app's NSUserDefaults connects.
    time.sleep(0.5)
    subprocess.run(
        ["xcrun", "simctl", "launch", sim.udid, BUNDLE_ID],
        check=True, capture_output=True,
    )
    # AppServices.initialize() runs on every launch: it clears diag.log
    # (DiagLog.clear) very early, then the Python backend logs
    # `[RNS] started identity=…` ~6–8 s in on a warm sim and longer on a cold
    # sim / slow CI runner. Poll for that readiness line instead of a flat
    # 8 s sleep — a fixed sleep that under-shoots hands control to the test
    # before the `lxma://` deep-link handler is registered, so the
    # location-toggle tap silently no-ops and the test times out later at
    # `wait_for_tapped_message` with no hint the app simply wasn't ready.
    # Gate on the clear first (current size drops below the pre-launch log,
    # with a short fallback since the clear is a truncate at init start) so we
    # don't match the *previous* session's `[RNS] started` line still on disk.
    pre_size = sim.diag_log.stat().st_size if sim.diag_log.exists() else 0
    cleared = pre_size == 0
    clear_fallback = time.time() + 3.0
    deadline = time.time() + 45.0
    while time.time() < deadline:
        size = sim.diag_log.stat().st_size if sim.diag_log.exists() else 0
        if not cleared and (size < pre_size or time.time() > clear_fallback):
            cleared = True
        if cleared and any(
            "[RNS] started identity=" in line for line in sim._tail_diag(LOG_TAIL_LINES)
        ):
            break
        time.sleep(0.5)
    else:
        pytest.fail(
            "Columba did not log `[RNS] started identity=…` within 45 s of "
            "relaunch — AppServices.initialize is stuck or slower than expected, "
            "so the location-toggle deep link would no-op against an unready app."
        )
