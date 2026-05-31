"""iOS-Columba ⇄ Sideband interop round-trips for LXMF attachment fields.

Each test exercises the *wire* path (LxmfFieldCodec.buildFieldMap → LXMessage.pack
→ RNS encrypt → over rnsd loopback → Sideband's LXMRouter delivery callback)
against the reference Sideband implementation, so a wire-format regression on
either side shows up immediately.

The send-side is driven through the `lxma://test-send` URL handler (added in
the same change that landed this suite) — bypassing the SwiftUI photo / file
picker so these tests pin the LXMF-wire path, not the UIKit picker stack.
The picker-driven path is exercised separately by Tests/RNSAPITests/
AttachmentFieldRoundTripTests + by the existing Maestro `send_text_to_peer`
flow.

Run with:
    cd Tests/interop
    ~/.reticulum-host/venv/bin/pytest -v test_attachments.py
"""

from __future__ import annotations
import time
from pathlib import Path
import sys

import pytest

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "fixtures"))
from make_test_image import png_bytes, jpeg_bytes, file_bytes  # noqa: E402


# ─────────────────────────────────────────────────────────────────────────
# Text — sanity baseline. If this fails the whole harness is broken.
# ─────────────────────────────────────────────────────────────────────────


def test_text_ios_to_sideband(sim, sideband):
    """iOS sends a short text via OPPORTUNISTIC; Sideband sees it on the tap."""
    body = f"text-ios-to-sideband-{int(time.time()*1000)}"
    result = sim.test_send(to_hex=sideband.identity_hex, content=body)
    assert result.error is None, f"iOS-side send failed: {result.error}"
    assert result.sent_hash_hex, "iOS didn't surface a message hash"

    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        content_match=body,
        timeout=30.0,
    )
    assert lxm.signature_validated, "Sideband couldn't verify iOS's signature"
    # The message hash carried in the iOS delivery event must match what
    # Sideband computes from the unpacked wire bytes — pins the LXMF pack/
    # unpack pair against drift.
    assert lxm.hash.hex() == result.sent_hash_hex


# ─────────────────────────────────────────────────────────────────────────
# Image (FIELD_IMAGE = 0x06) — the on-wire shape is `[format_str, bytes]`.
# We pin all three desired-methods (OPPORTUNISTIC / DIRECT / PROPAGATED) so
# a fallback change in upstream LXMF surfaces as a test failure instead of
# silently downgrading behaviour.
# ─────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("image_format,image_factory", [
    ("png", png_bytes),
    ("jpeg", jpeg_bytes),
])
def test_image_ios_to_sideband_opportunistic(sim, sideband, image_format, image_factory):
    """iOS → Sideband, OPPORTUNISTIC. Small payload fits in one packet so no
    fallback to DIRECT happens; this is the happy path."""
    img = image_factory()
    body = f"img-opp-{image_format}-{int(time.time()*1000)}"
    result = sim.test_send(
        to_hex=sideband.identity_hex,
        content=body,
        method="opportunistic",
        image_bytes=img,
        image_format=image_format,
    )
    assert result.error is None, result.error
    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=0x06,  # FIELD_IMAGE
        content_match=body,
        timeout=30.0,
    )
    _assert_image_field(lxm, expected_format=image_format, expected_bytes=img)


def test_image_ios_to_sideband_direct(sim, sideband):
    """iOS → Sideband, DIRECT (explicit). LXMF opens an RNS.Link to the
    delivery destination and sends the message as a Resource."""
    img = png_bytes()
    body = f"img-direct-{int(time.time()*1000)}"
    result = sim.test_send(
        to_hex=sideband.identity_hex,
        content=body,
        method="direct",
        image_bytes=img,
        image_format="png",
    )
    assert result.error is None, result.error
    assert result.method == "direct"
    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=0x06,
        content_match=body,
        timeout=60.0,
    )
    _assert_image_field(lxm, expected_format="png", expected_bytes=img)


def test_image_ios_to_sideband_propagated(sim, sideband):
    """iOS → Sideband, PROPAGATED. iOS uploads to a propagation node (lxmd
    on the host); Sideband must sync from the same PN to pick the message
    up. Requires lxmd to be running and announcing as `lxmf.propagation`."""
    pn_hex = sim.auto_propagation_node_hex()
    if not pn_hex:
        pytest.skip(
            "No lxmf.propagation announce with a non-empty name seen on "
            "iOS. lxmd's announce_interval is 5 min and every Maestro "
            "launchApp wipes diag.log, so the per-launch slice rarely "
            "catches a sighting in suite order. Either start lxmd with "
            "`node_name = …` set + run again, or pass the hex directly: "
            "`PROP_NODE_HEX=<lxmd-hash> pytest …`."
        )

    # iOS-side: explicitly wire the PN. PropagationNodeManager's auto-select
    # is best-effort and isn't guaranteed to fire before the first
    # PROPAGATED send (timing of announce ingestion vs send).
    sim.set_propagation_node(pn_hex)

    img = png_bytes()
    body = f"img-prop-{int(time.time()*1000)}"
    result = sim.test_send(
        to_hex=sideband.identity_hex,
        content=body,
        method="propagated",
        image_bytes=img,
        image_format="png",
    )
    assert result.error is None, result.error
    assert result.method == "propagated"

    # Sideband-side: ensure we're pointed at the same PN, then poll-sync
    # with retries. iOS uploads the message to lxmd as an RNS Link Resource
    # (multi-roundtrip), which on a freshly bootstrapped path can take
    # several seconds; Sideband's sync needs to fire AFTER that's committed
    # to lxmd's queue. We retry a few times in case the first sync races
    # the upload.
    sideband._core.set_active_propagation_node(bytes.fromhex(pn_hex))
    last_assertion = None
    for attempt in range(6):
        time.sleep(5.0 if attempt == 0 else 3.0)
        sideband.sync_propagation_messages(limit=20)
        try:
            lxm = sideband.wait_for_tapped_message(
                from_hex=sim.lxmf_delivery_hex,
                field_id=0x06,
                content_match=body,
                timeout=8.0,
            )
            _assert_image_field(lxm, expected_format="png", expected_bytes=img)
            return
        except AssertionError as e:
            last_assertion = e
            print(f"[PROP] attempt {attempt+1}/6 didn't find message yet; retrying sync", flush=True)
    raise last_assertion or AssertionError("propagated send never landed on Sideband")


# ─────────────────────────────────────────────────────────────────────────
# File attachment (FIELD_FILE_ATTACHMENTS = 0x05) — wire shape is
# `[[name, bytes], …]` (a list of 2-tuples, since one message can carry
# multiple files). The test-send URL ships exactly one file; the multi-file
# encoding case is covered by the unit-test round-trip in
# Tests/RNSAPITests/AttachmentFieldRoundTripTests.
# ─────────────────────────────────────────────────────────────────────────


def test_file_ios_to_sideband(sim, sideband):
    """iOS → Sideband, single file attachment under OPPORTUNISTIC."""
    payload = file_bytes()
    name = "interop.txt"
    body = f"file-{int(time.time()*1000)}"
    result = sim.test_send(
        to_hex=sideband.identity_hex,
        content=body,
        method="opportunistic",
        file_bytes=payload,
        file_name=name,
    )
    assert result.error is None, result.error
    lxm = sideband.wait_for_tapped_message(
        from_hex=sim.lxmf_delivery_hex,
        field_id=0x05,  # FIELD_FILE_ATTACHMENTS
        content_match=body,
        timeout=30.0,
    )
    files = lxm.fields[0x05]
    assert isinstance(files, list) and len(files) == 1, f"expected one file, got {files!r}"
    first = files[0]
    # Sideband / upstream LXMF decode the filename as either bytes or str
    # depending on msgpack typing the sender chose. iOS's LxmfFieldCodec emits
    # `[String, Data]` → msgpack str/bin → Python decodes to (str, bytes).
    filename = first[0] if isinstance(first[0], str) else first[0].decode("utf-8")
    data = first[1] if isinstance(first[1], (bytes, bytearray)) else bytes(first[1])
    assert filename == name
    assert bytes(data) == payload


# ─────────────────────────────────────────────────────────────────────────
# Reverse direction — Sideband → iOS. Asserts the iOS bubble appears in
# the chat UI for the corresponding peer, by reading the iOS app's local
# DB (LXMFDatabase) via the simulator's data container.
# ─────────────────────────────────────────────────────────────────────────


def test_text_sideband_to_ios(sim, sideband):
    """Sideband sends a plain-text LXMF message; iOS persists it and the
    chat bubble renders the text. Pins the inbound *text* path (LXMRouter
    delivery → IncomingMessageHandler → LXMFDatabase → MessageBubble) for
    the reverse direction — the forward half is `test_text_ios_to_sideband`.
    Until now the reverse direction only had image + file coverage; plain
    text was the gap."""
    body = f"text-from-sideband-{int(time.time()*1000)}"
    assert sideband.send_text(
        dest_hex=sim.lxmf_delivery_hex,
        content=body,
    ), "Sideband-side send_text returned False"

    _wait_for_diag_inbound(sim, content=body)
    sim.assert_bubble_visible(content=body)


def test_image_sideband_to_ios(sim, sideband):
    """Sideband sends a PNG to iOS; the iOS-side persistence (LXMFDatabase
    + MessageBubble.init(from record:)) must surface the image bytes
    through `MessageRecord.packedLxmf` → `LxmfFieldCodec.unpack` →
    `Message.imageData`, AND the SwiftUI message bubble must render the
    image view. Pins both halves of the inbound stack — the prior
    diag.log heuristic only proved the LXMRouter callback fired."""
    img = png_bytes()
    body = f"img-from-sideband-{int(time.time()*1000)}"
    assert sideband.send_image(
        dest_hex=sim.lxmf_delivery_hex,
        content=body,
        image_bytes=img,
        image_format="png",
    ), "Sideband-side send_image returned False"

    # Wait for iOS to record the inbound delivery so the conversation row
    # exists in Chats before Maestro tries to tap it. Sideband's send is
    # async — `send_image` returns on enqueue.
    _wait_for_diag_inbound(sim, content=body)

    sim.assert_bubble_visible(content=body, has_image=True)


def test_file_sideband_to_ios(sim, sideband):
    """Sideband sends a small file; iOS persists it AND the bubble renders
    a file chip whose label carries the filename."""
    payload = file_bytes(b"reverse-file-interop\n")
    name = "from-sideband.txt"
    body = f"file-from-sideband-{int(time.time()*1000)}"
    assert sideband.send_file(
        dest_hex=sim.lxmf_delivery_hex,
        content=body,
        filename=name,
        data=payload,
    ), "Sideband-side send_file returned False"

    _wait_for_diag_inbound(sim, content=body)

    sim.assert_bubble_visible(content=body, has_file_name=name)


def _wait_for_diag_inbound(sim, *, content: str, timeout: float = 30.0) -> None:
    """Block until `[RNS] inbound` for this content lands in diag.log so
    the Chats list has the conversation row Maestro will tap on."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for line in reversed(sim._tail_diag(800)):
            if "[RNS] inbound source=" in line and content in line:
                return
        time.sleep(0.4)
    pytest.fail(f"iOS didn't record inbound for {content!r} within {timeout}s")


# ─────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────


def _assert_image_field(lxm, *, expected_format: str, expected_bytes: bytes) -> None:
    """Sideband-side assertion that the inbound FIELD_IMAGE matches what we sent.

    Format slot can arrive as either a Python `str` (iOS's LxmfFieldCodec
    serialises Swift `String` as msgpack str) or `bytes` (LXMF-kt's
    canonical form). Accept both so the same assertion works against any
    iOS/Android/Sideband sender."""
    field = lxm.fields[0x06]
    assert isinstance(field, list) and len(field) == 2, f"FIELD_IMAGE shape wrong: {field!r}"
    fmt = field[0] if isinstance(field[0], str) else field[0].decode("utf-8")
    data = field[1] if isinstance(field[1], (bytes, bytearray)) else bytes(field[1])
    assert fmt == expected_format, f"format mismatch: {fmt!r} != {expected_format!r}"
    assert bytes(data) == expected_bytes, f"image bytes mismatch (got {len(data)}B, expected {len(expected_bytes)}B)"
