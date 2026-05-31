"""iOS-Columba ⇄ Sideband interop round-trips for LXMF location telemetry.

Exercises `RnsTelemetry.sendLocationTelemetry` on the iOS Python backend
(including the cease path, which is just sendLocationTelemetry with a
zeroed Telemeter body + cease meta) against a Sideband reference peer:

  * `test_location_ios_to_sideband` — iOS sends a packed Telemeter
    payload; Sideband decodes it back to lat/lon/timestamp.
  * `test_location_with_custom_meta_ios_to_sideband` — same, plus an
    `approxRadius` JSON in FIELD_CUSTOM_META so the receiver can read
    Columba-specific precision-coarsening metadata.
  * `test_cease_ios_to_sideband` — iOS sends a cease signal; the wire
    carries a zeroed Telemeter (FIELD_TELEMETRY 0x02) + msgpack
    `{"cease": true}` (FIELD_CUSTOM_META 0xFD), matching Android Columba.

The Telemeter payload itself is built using Sideband's own `Telemeter`
class (via `peer_sideband.SidebandPeer`) so the test payload is the
exact bytes Sideband expects on the wire — pinning Columba's send
shape against drift in the Sideband-canonical encoder.

Receive direction (Sideband→iOS) is covered by
`test_location_sideband_to_ios`: Sideband sends a location telemetry
(plus a FIELD_ICON_APPEARANCE), iOS decodes it in
`LocationSharingManager.handleIncomingTelemetry`, and a peer pin
renders on the Map screen. (The old `#if COLUMBA_LOCATION_ENABLED`
compile gate this used to be blocked on was removed on 2026-05-28.)
"""

from __future__ import annotations
import re
import time
from pathlib import Path

import pytest


def _build_sideband_location(sideband, *, lat: float, lon: float, alt: float = 0.0,
                              accuracy: float = 5.0, ts: int | None = None) -> bytes:
    """Build a Sideband-canonical Telemeter payload using Sideband's own
    `Telemeter` from sbapp.sideband.sense. Returns the packed bytes that
    go on the wire as FIELD_TELEMETRY (0x02)."""
    from sbapp.sideband.sense import Telemeter  # type: ignore
    t = Telemeter(from_packed=True)
    t.synthesize("location")
    loc = t.sensors["location"]
    loc.data = {
        "latitude": lat,
        "longitude": lon,
        "altitude": alt,
        "speed": 0.0,
        "bearing": 0.0,
        "accuracy": accuracy,
        "last_update": ts or int(time.time()),
    }
    return t.packed()


def _decode_sideband_location(packed: bytes) -> dict:
    """Decode a Telemeter payload back to a lat/lon dict via Sideband's
    parser. Asserts the round-trip on this side too — if Sideband's
    encoder + parser don't round-trip locally, no point comparing to
    what iOS sent."""
    from sbapp.sideband.sense import Telemeter
    t = Telemeter.from_packed(packed)
    return t.read_all().get("location", {})


def test_location_ios_to_sideband(sim, sideband):
    """iOS → Sideband location telemetry. Asserts the decoded lat/lon
    on the Sideband side matches what iOS was asked to send."""
    expect_lat, expect_lon = 37.7749, -122.4194  # San Francisco — test data, not real
    packed = _build_sideband_location(sideband, lat=expect_lat, lon=expect_lon, accuracy=12.0)

    # Snapshot tap count BEFORE the send. Telemetry messages carry empty
    # content, so we can't use `content_match=` to disambiguate from
    # earlier test runs' taps — index baseline is the workable filter.
    baseline = len(sideband._taps)
    outcome_line = sim.test_send_telemetry(
        to_hex=sideband.identity_hex,
        packed=packed,
    )
    assert "[TEST-TELEMETRY] send outcome=" in outcome_line, outcome_line
    assert "error=" not in outcome_line, outcome_line

    # Sideband-side: FIELD_TELEMETRY (0x02) lands as raw bytes (msgpack
    # `bin`); decode via Telemeter to assert lat/lon survived the wire.
    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=0x02,
        baseline=baseline,
        timeout=30.0,
    )
    telemetry_bytes = lxm.fields[0x02]
    assert isinstance(telemetry_bytes, (bytes, bytearray)), \
        f"FIELD_TELEMETRY arrived as {type(telemetry_bytes).__name__}, not bytes"
    loc = _decode_sideband_location(bytes(telemetry_bytes))
    assert abs(loc.get("latitude", 0) - expect_lat) < 1e-6
    assert abs(loc.get("longitude", 0) - expect_lon) < 1e-6


def test_location_with_custom_meta_ios_to_sideband(sim, sideband):
    """Same as above but with a Columba-specific FIELD_CUSTOM_META
    (0xFD) payload riding alongside. Tests that the extraFields slot
    handles the multi-key telemetry shape iOS Swift backend already
    emits (approxRadius for precision coarsening)."""
    packed = _build_sideband_location(sideband, lat=40.7128, lon=-74.0060, accuracy=8.0)
    # Columba meta on iOS Swift backend: JSON dict carrying approxRadius
    # in km, plus optional `expires` and `cease` flags. We don't assert
    # the parse on Sideband-side (Sideband doesn't read this key) — just
    # that the bytes survive intact.
    meta = b'{"approxRadius": 0.5}'

    baseline = len(sideband._taps)
    outcome_line = sim.test_send_telemetry(
        to_hex=sideband.identity_hex,
        packed=packed,
        custom_meta=meta,
    )
    assert "[TEST-TELEMETRY] send outcome=" in outcome_line, outcome_line

    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=0x02,
        baseline=baseline,
        timeout=30.0,
    )
    assert 0xFD in (lxm.fields or {}), \
        f"FIELD_CUSTOM_META missing from {sorted((lxm.fields or {}).keys())}"
    meta_bytes = lxm.fields[0xFD]
    assert bytes(meta_bytes) == meta


# Used to flake in suite order (~50 % on `pytest -v`) when an earlier test
# left `locationSharing_activePeers` populated — the chat-screen toggle
# would already be *on*, so the first tap turned it off instead of opening
# `LocationShareSheet`. The `clean_location_state` fixture (conftest.py)
# now resets that UserDefaults key + relaunches the app before each run,
# closing the flake. Any new test that drives the same toggle UI should
# request `clean_location_state` too.
def test_chat_toggle_starts_periodic_sharing(sim, sideband, clean_location_state, tmp_path_factory):
    """Drive the chat-screen location toggle (top-right) end-to-end:
    Maestro taps the toggle in MessagingView, picks a duration in
    LocationShareSheet, and asserts the LocationSharingManager fires
    its first telemetry send within the foreground send interval.

    Pins the UI path that ships in Columba — vs the `lxma://test-telemetry`
    URL handler tested above, which bypasses the picker / GPS-fix wait."""
    import subprocess

    # 1. Pre-grant location permission on the sim so the toggle doesn't
    #    block on the system Allow / Don't Allow dialog (the test would
    #    need a separate Maestro step to dismiss). The privacy CLI is
    #    idempotent — already-granted is a no-op.
    subprocess.run(
        ["xcrun", "simctl", "privacy", sim.udid, "grant", "location",
         "network.columba.Columba"], check=True, capture_output=True
    )
    # 2. Stamp a simulated GPS fix so CLLocationManager.location is
    #    non-nil before the first periodic send runs. Without this the
    #    manager's `sendLocationUpdateToPeer` would short-circuit on
    #    `location == nil` and we'd time out waiting on the tap.
    expect_lat, expect_lon = 47.6062, -122.3321
    subprocess.run(
        ["xcrun", "simctl", "location", sim.udid, "set",
         f"{expect_lat},{expect_lon}"], check=True, capture_output=True
    )

    baseline = len(sideband._taps)

    # 3. Drive the Maestro flow: nav → tap location toggle → pick "15 min".
    flow_path = str(Path(__file__).parent / "flows" / "share_location_chat_toggle.yaml")
    r = subprocess.run(
        ["maestro", "--device", sim.udid, "test", flow_path,
         "-e", "PEER_DISPLAY=Anonymous Peer", "-e", "DURATION=15 min"],
        capture_output=True, text=True, timeout=120,
    )
    if r.returncode != 0:
        pytest.fail(f"Maestro share-location flow failed:\n{r.stdout}\n{r.stderr}")

    # 4. CLLocationManager on the sim is racy: a single `simctl location
    #    set` before `startUpdatingLocation()` fires doesn't reliably get
    #    delivered, and the sim logs `kCLErrorLocationUnknown` until a fix
    #    push lands *after* the manager started observing. We re-push the
    #    location periodically for a few seconds to make sure at least one
    #    fix reaches `locationManager.location` before the manager's
    #    initial-send Task wakes up. Cheap (each call is a few ms).
    for _ in range(8):
        subprocess.run(
            ["xcrun", "simctl", "location", sim.udid, "set",
             f"{expect_lat},{expect_lon}"], check=True, capture_output=True
        )
        time.sleep(0.6)

    # 5. Wait for the LocationSharingManager's first periodic send to
    #    land on Sideband. The manager fires an initial send ~2 s after
    #    `startSharing(...)` once it has a fix.
    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=0x02,
        baseline=baseline,
        timeout=75.0,  # foreground interval is 60 s; cover one full beat.
    )
    telemetry_bytes = lxm.fields[0x02]
    assert isinstance(telemetry_bytes, (bytes, bytearray)), \
        f"FIELD_TELEMETRY arrived as {type(telemetry_bytes).__name__}, not bytes"

    # 5. Decode the Telemeter blob and assert the lat/lon are close to
    #    what we asked the sim to simulate. CLLocationManager's
    #    `desiredAccuracy = kCLLocationAccuracyBest` lets the simulated
    #    fix through unmodified; precision coarsening on
    #    `locationPrecisionRadius` would clamp the value, but the
    #    default precision in a fresh sim install is 0 (precise).
    from sbapp.sideband.sense import Telemeter  # type: ignore
    t = Telemeter.from_packed(bytes(telemetry_bytes))
    loc = t.read_all().get("location", {})
    assert abs(loc.get("latitude", 0) - expect_lat) < 0.01, \
        f"lat drift too large: got {loc.get('latitude')}, expected {expect_lat}"
    assert abs(loc.get("longitude", 0) - expect_lon) < 0.01, \
        f"lon drift too large: got {loc.get('longitude')}, expected {expect_lon}"


def test_cease_ios_to_sideband(sim, sideband):
    """iOS → Sideband cease signal. The wire shape mirrors Android Columba's
    sendCeaseMessage: an empty-content message carrying a zeroed-location
    Telemeter blob (FIELD_TELEMETRY 0x02) PLUS Columba's FIELD_CUSTOM_META
    (0xFD) = **msgpack** `{"cease": true}` (NOT JSON). Android's receive path
    requires the Telemeter body present before it reads the cease flag, and
    decodes the meta as msgpack — a JSON byte string is silently dropped
    there, so both the format and the FIELD_TELEMETRY presence matter."""
    from RNS.vendor import umsgpack  # RNS-bundled pure-python msgpack

    baseline = len(sideband._taps)
    outcome_line = sim.test_send_telemetry(
        to_hex=sideband.identity_hex,
        cease=True,
    )
    assert "[TEST-TELEMETRY] cease outcome=" in outcome_line, outcome_line
    assert "error=" not in outcome_line, outcome_line

    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=0xFD,  # FIELD_CUSTOM_META carries the cease flag
        baseline=baseline,
        timeout=30.0,
    )
    # FIELD_CUSTOM_META is msgpack {"cease": true} (Android-canonical), not JSON.
    meta_bytes = lxm.fields[0xFD]
    assert isinstance(meta_bytes, (bytes, bytearray))
    meta = umsgpack.unpackb(bytes(meta_bytes))
    assert isinstance(meta, dict) and meta.get("cease") is True, \
        f"cease meta wasn't msgpack {{cease: true}}: {meta!r}"
    # Android bails unless a Telemeter body (FIELD_TELEMETRY 0x02) is present.
    assert 0x02 in lxm.fields, "cease message missing FIELD_TELEMETRY (0x02)"
    # Content should be empty on a cease.
    assert lxm.content == b"" or lxm.content is None


# ─────────────────────────────────────────────────────────────────────────
# Receive direction — Sideband → iOS. Asserts a peer pin renders on the
# Map screen (and carries the peer's MDI icon), pinning the inbound
# FIELD_TELEMETRY + FIELD_ICON_APPEARANCE → LocationSharingManager →
# MapLibre marker path.
# ─────────────────────────────────────────────────────────────────────────


def _wait_for_loc_recv(sim, *, timeout: float = 30.0) -> str:
    """Block until `LocationSharingManager.handleIncomingTelemetry` logs a
    decoded inbound telemetry line (`[LOC-RECV] …`) to diag.log, and
    return it. The line mirrors the decoded peer/lat/lon/icon because the
    MapLibre marker itself isn't reachable from the accessibility tree."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for line in reversed(sim._tail_diag(800)):
            if "[LOC-RECV]" in line:
                return line
        time.sleep(0.4)
    pytest.fail(f"iOS never logged [LOC-RECV] for inbound telemetry within {timeout}s")


def test_location_sideband_to_ios(sim, sideband):
    """Sideband → iOS location telemetry with an icon appearance.

    Sideband sends a Sideband-canonical Telemeter location plus a
    FIELD_ICON_APPEARANCE (0x04) triple. iOS must:
      1. decode FIELD_TELEMETRY in `handleIncomingTelemetry`, add the peer
         to `LocationSharingManager.peerLocations`, and render a pin on
         the Map screen — asserted via the `map_peer_count` badge (the
         MapLibre marker is GL-drawn and not in the a11y tree), and
      2. decode the FIELD_ICON_APPEARANCE into `PeerLocation.iconAppearance`
         with the peer's MDI glyph + colours surviving the wire — asserted
         off the `[LOC-RECV]` diag line, which mirrors what the marker
         renders. The loc-map screenshot is the visual record of the glyph.

    Coordinates and colours are arbitrary test data."""
    expect_lat, expect_lon = 37.7749, -122.4194
    icon_name, fg_hex, bg_hex = "map-marker", "ffffff", "e91e63"
    assert sideband.send_location_telemetry(
        dest_hex=sim.lxmf_delivery_hex,
        lat=expect_lat,
        lon=expect_lon,
        accuracy=12.0,
        icon=(icon_name, fg_hex, bg_hex),
    ), "Sideband-side send_location_telemetry returned False"

    # Decoded telemetry + icon round-trip (the part the GL marker can't
    # expose). Capture first — it's logged on receipt regardless of UI
    # state, so it's independent of the map-navigation step below.
    line = _wait_for_loc_recv(sim)
    m = re.search(
        r"\[LOC-RECV\] peer=(\w+) lat=(-?[\d.]+) lon=(-?[\d.]+) "
        r"icon=(\S+) fg=(\S+) bg=(\S+)",
        line,
    )
    assert m, f"[LOC-RECV] line didn't parse: {line!r}"
    peer, lat, lon, icon, fg, bg = m.groups()
    assert peer == sideband.identity_hex[:len(peer)], \
        f"telemetry attributed to {peer}, expected {sideband.identity_hex[:len(peer)]}"
    assert abs(float(lat) - expect_lat) < 1e-4, f"lat drift: {lat}"
    assert abs(float(lon) - expect_lon) < 1e-4, f"lon drift: {lon}"
    assert icon == icon_name, f"icon name didn't round-trip: {icon!r}"
    assert fg == fg_hex, f"fg colour didn't round-trip: {fg!r}"
    assert bg == bg_hex, f"bg colour didn't round-trip: {bg!r}"

    # Pin renders on the Map screen (proves peerLocations reached the UI).
    sim.assert_peer_pin_visible()
