"""iOS-Columba ⇄ Sideband interop matrix for LXMF FIELD_AUDIO (0x07).

Mirrors test_attachments.py but for the voice-message field, per the
plan's Section 9 target matrix:

  | iOS Columba | Sideband | 1200/2400/3200 | every Opus profile |
  | Sideband    | iOS      | 1200/2400/3200 | every Opus profile |

The load-bearing cell (plan §4.1) is Sideband→iOS **Opus**: Sideband's
LXST/libopusfile path rejects Ogg with packet-start granules, so a
Sideband-toolchain Ogg that iOS decodes and plays end-to-end proves the
inbound Ogg/Opus path against the real reference. The outbound
iOS→Sideband Ogg granule fix is pinned separately by
OggOpusFileWriterTests (unit) and by Sideband capturing the iOS Ogg
byte-for-byte (wire half) below.

Fixtures are generated at runtime (fixtures/make_voice_fixtures.py):
  - Codec2: pycodec2 raw frame concatenation (no header byte), exactly
    what iOS Codec2RawFile and Android emit.
  - Opus: ffmpeg libopus at each iOS profile's rate/channel count.
Both artifact types are ffprobe-validated before the matrix runs, per
the plan.

Run with:
    cd Tests/interop
    ~/.reticulum-host/venv/bin/pytest -v test_voice.py
"""

from __future__ import annotations
import time
from pathlib import Path

import pytest

HERE = Path(__file__).parent
sys_path_added = False
import sys
if str(HERE / "fixtures") not in sys.path:
    sys.path.insert(0, str(HERE / "fixtures"))
    sys_path_added = True

from make_voice_fixtures import generate_all  # noqa: E402

# Wire modes (LxmfFields.AM_*).
AM_CODEC2_1200 = 0x04
AM_CODEC2_2400 = 0x08
AM_CODEC2_3200 = 0x09
AM_OPUS_OGG = 0x10
FIELD_AUDIO = 0x07


@pytest.fixture(scope="module")
def voice_fixtures(tmp_path_factory) -> Path:
    """Generate the fixtures once per module run; return the directory."""
    d = tmp_path_factory.mktemp("voice_fixtures")
    generate_all(str(d))
    return d


def _fix(voice_fixtures: Path, name: str, ext: str) -> bytes:
    return (voice_fixtures / f"{name}.{ext}").read_bytes()


# ─────────────────────────────────────────────────────────────────────────
# iOS → Sideband (iOS produces the field-7 payload; Sideband must capture
# it with the matching mode + byte-for-byte payload).
# ─────────────────────────────────────────────────────────────────────────


def _assert_audio_field(lxm, *, expected_mode: int, expected_bytes: bytes) -> None:
    """Sideband-side assertion that the inbound FIELD_AUDIO matches what
    iOS sent. The mode slot may arrive as any signed/unsigned int after
    the msgpack round-trip; the payload must be byte-identical."""
    assert FIELD_AUDIO in lxm.fields, f"FIELD_AUDIO missing: fields={sorted(lxm.fields.keys())}"
    field = lxm.fields[FIELD_AUDIO]
    assert isinstance(field, list) and len(field) == 2, f"FIELD_AUDIO shape wrong: {field!r}"
    mode = int(field[0])
    assert mode == expected_mode, f"audio mode mismatch: 0x{mode:02x} != 0x{expected_mode:02x}"
    data = field[1] if isinstance(field[1], (bytes, bytearray)) else bytes(field[1])
    assert bytes(data) == expected_bytes, (
        f"audio payload mismatch: got {len(data)}B, expected {len(expected_bytes)}B"
    )


@pytest.mark.parametrize("name,mode", [
    ("c2_1200", AM_CODEC2_1200),
    ("c2_2400", AM_CODEC2_2400),
    ("c2_3200", AM_CODEC2_3200),
])
def test_codec2_ios_to_sideband(sim, sideband, voice_fixtures, name, mode):
    """iOS sends a Codec2 voice note; Sideband captures field 7 with the
    exact mode and byte-identical raw-frame payload."""
    payload = _fix(voice_fixtures, name, "c2")
    body = f"v-c2-{name}-{int(time.time() * 1000)}"
    result = sim.test_send(
        to_hex=sideband.identity_hex,
        content=body,
        method="opportunistic",
        audio_bytes=payload,
        audio_mode=mode,
    )
    assert result.error is None, f"iOS-side send failed: {result.error}"
    assert result.sent_hash_hex, "iOS didn't surface a message hash"
    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=FIELD_AUDIO,
        content_match=body,
        timeout=30.0,
    )
    assert lxm.signature_validated, "Sideband couldn't verify iOS's signature"
    assert lxm.hash.hex() == result.sent_hash_hex
    _assert_audio_field(lxm, expected_mode=mode, expected_bytes=payload)


def test_opus_ios_to_sideband(sim, sideband, voice_fixtures):
    """iOS sends a Medium-Quality (24k mono) Ogg/Opus note; Sideband must
    capture field 7 with mode 0x10 and the byte-identical Ogg. Sideband
    persisting the Ogg without error is the wire half of the granule-fix
    story (the decode half is pinned by OggOpusFileWriterTests + the
    Sideband→iOS Opus cell below)."""
    payload = _fix(voice_fixtures, "opus_medium", "ogg")
    body = f"v-opus-medium-{int(time.time() * 1000)}"
    result = sim.test_send(
        to_hex=sideband.identity_hex,
        content=body,
        method="opportunistic",
        audio_bytes=payload,
        audio_mode=AM_OPUS_OGG,
    )
    assert result.error is None, f"iOS-side send failed: {result.error}"
    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=FIELD_AUDIO,
        content_match=body,
        timeout=30.0,
    )
    _assert_audio_field(lxm, expected_mode=AM_OPUS_OGG, expected_bytes=payload)


# ─────────────────────────────────────────────────────────────────────────
# Sideband → iOS (Sideband produces the field-7 payload; iOS must persist
# it AND render a playable voice bubble).
# ─────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("name,mode", [
    ("c2_1200", AM_CODEC2_1200),
    ("c2_2400", AM_CODEC2_2400),
    ("c2_3200", AM_CODEC2_3200),
])
def test_codec2_sideband_to_ios(sim, sideband, voice_fixtures, name, mode):
    """Sideband sends a Codec2 voice note; iOS persists it and the bubble
    renders a playable play-control (not the 'unavailable' state)."""
    payload = _fix(voice_fixtures, name, "c2")
    body = f"v-c2-{name}-from-sideband-{int(time.time() * 1000)}"
    assert sideband.send_audio(
        dest_hex=sim.lxmf_delivery_hex,
        content=body,
        audio_bytes=payload,
        codec_tag=mode,
    ), "Sideband-side send_audio returned False"
    _wait_for_diag_inbound(sim, sideband, content=body)
    sim.assert_voice_bubble_visible(content=body, playable=True)


@pytest.mark.parametrize("name", ["opus_medium", "opus_high", "opus_max"])
def test_opus_sideband_to_ios(sim, sideband, voice_fixtures, name):
    """Sideband sends an Ogg/Opus note (Sideband toolchain's ffmpeg
    output); iOS must decode it and render a PLAYABLE voice bubble. This
    is the load-bearing cell of the plan's interop matrix - the exact
    path that failed on Android before the granule fix. A malformed
    granule would surface voice_bubble_unavailable/error, not the play
    control."""
    payload = _fix(voice_fixtures, name, "ogg")
    body = f"v-opus-{name}-from-sideband-{int(time.time() * 1000)}"
    assert sideband.send_audio(
        dest_hex=sim.lxmf_delivery_hex,
        content=body,
        audio_bytes=payload,
        codec_tag=AM_OPUS_OGG,
    ), "Sideband-side send_audio returned False"
    _wait_for_diag_inbound(sim, sideband, content=body)
    sim.assert_voice_bubble_visible(content=body, playable=True)
    # Playback state: tap the play control and confirm the progress text
    # advances (or the state leaves .loading) without an error. This is
    # the actual decode + AVAudioPlayer exercise.
    sim.assert_voice_playback_advances(content=body, timeout=25.0)


# ─────────────────────────────────────────────────────────────────────────
# helpers
# ─────────────────────────────────────────────────────────────────────────


def _wait_for_diag_inbound(sim, sideband, *, content: str, timeout: float = 30.0) -> None:
    """Same correlation as test_attachments._wait_for_diag_inbound, but
    inlined so this module is self-contained."""
    expected_len = len(content.encode("utf-8"))
    source8 = sideband.identity_hex[:8]
    before_size = sim.diag_log.stat().st_size if sim.diag_log.exists() else 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        for line in sim._read_diag_since(before_size):
            if (f"[RNS] inbound source={source8} " in line
                    and f"len={expected_len} " in line):
                return
        time.sleep(0.4)
    pytest.fail(
        f"iOS didn't record inbound (source={source8} len={expected_len}) "
        f"within {timeout}s"
    )
