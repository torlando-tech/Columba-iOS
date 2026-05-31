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


def _yaml_escape(s: str) -> str:
    """Escape a string for safe use inside a double-quoted YAML scalar.
    Maestro reads the flow file line-by-line as YAML, so backslashes, quotes,
    or control characters in user content would break the matcher silently —
    a newline in particular splits the scalar into two YAML entries. Tests
    typically use safe ASCII timestamps so this rarely fires — defensive.
    Backslash is escaped first so the sequences we introduce below aren't
    double-escaped."""
    return (
        s.replace("\\", "\\\\")
         .replace("\"", "\\\"")
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
        """Local RNS identity hash hex (the `[PY] started identity=…` line)."""
        if self._cached_identity_hex is not None:
            return self._cached_identity_hex
        for line in self._tail_diag(LOG_TAIL_LINES * 4):
            m = re.search(r"\[PY\] started identity=([0-9a-f]+)\s+destination=", line)
            if m:
                self._cached_identity_hex = m.group(1)
                return self._cached_identity_hex
        pytest.fail("Couldn't find `[PY] started identity=…` in diag.log")

    @property
    def lxmf_delivery_hex(self) -> str:
        """Local LXMF delivery-destination hash hex (the `destination=…` half)."""
        if self._cached_lxmf_delivery_hex is not None:
            return self._cached_lxmf_delivery_hex
        for line in self._tail_diag(LOG_TAIL_LINES * 4):
            m = re.search(r"\[PY\] started identity=[0-9a-f]+\s+destination=([0-9a-f]+)", line)
            if m:
                self._cached_lxmf_delivery_hex = m.group(1)
                return self._cached_lxmf_delivery_hex
        pytest.fail("Couldn't find `destination=…` in diag.log")

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
                r"\[PY\] announce dest=([0-9a-f]+)\s+aspect=lxmf\.propagation\s+name=\"([^\"]*)\"",
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
        let the diag.log `[PY] inbound` proxy assertion pass), but this
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
            "- tapOn:",
            "    text: \"Chats\"",
            "    optional: true",
            "- waitForAnimationToEnd: { timeout: 2000 }",
            f"- tapOn: \"{peer_display_name}\"",
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
            # the [PY] started count and diag.log untouched. The app can end
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
    # AppServices.initialize() runs on every launch and the Python
    # backend's `[PY] started identity=…` log line lands ~6–8 s in on
    # a warm sim. Match the original inline timing so behaviour is
    # unchanged from the version that lived in the test body.
    time.sleep(8.0)
