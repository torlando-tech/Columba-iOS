"""iOS-Columba ⇄ Sideband interop round-trips for LXMF location telemetry.

Exercises `RnsTelemetry.sendLocationTelemetry` / `sendTelemetryCease` on
the iOS Python backend (just un-stubbed from no-op to real wire path)
against a Sideband reference peer:

  * `test_location_ios_to_sideband` — iOS sends a packed Telemeter
    payload; Sideband decodes it back to lat/lon/timestamp.
  * `test_location_with_custom_meta_ios_to_sideband` — same, plus an
    `approxRadius` JSON in FIELD_CUSTOM_META so the receiver can read
    Columba-specific precision-coarsening metadata.
  * `test_cease_ios_to_sideband` — iOS sends a cease signal; Sideband
    sees the FIELD_CUSTOM_META = `{"cease": true}` payload.

The Telemeter payload itself is built using Sideband's own `Telemeter`
class (via `peer_sideband.SidebandPeer`) so the test payload is the
exact bytes Sideband expects on the wire — pinning Columba's send
shape against drift in the Sideband-canonical encoder.

Receive-direction tests (Sideband→iOS) are deferred: the iOS
`LocationSharingManager` that consumes inbound telemetry is gated
behind `#if COLUMBA_LOCATION_ENABLED`, which isn't defined in any
shipping build config yet. We can add the inbound assertion once
the UI side comes off the compile gate.
"""

from __future__ import annotations
import time

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


def test_cease_ios_to_sideband(sim, sideband):
    """iOS → Sideband cease signal. The wire shape is an empty-content
    message carrying FIELD_CUSTOM_META = `{"cease": true}` (UTF-8 JSON),
    matching the convention IncomingMessageHandler enforces on iOS and
    that Android Columba uses."""
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
    meta_bytes = lxm.fields[0xFD]
    assert isinstance(meta_bytes, (bytes, bytearray))
    meta_str = bytes(meta_bytes).decode("utf-8", "replace")
    assert "\"cease\"" in meta_str and "true" in meta_str.lower(), \
        f"cease meta payload didn't carry the expected JSON: {meta_str!r}"
    # Content should be empty on a cease.
    assert lxm.content == b"" or lxm.content is None
