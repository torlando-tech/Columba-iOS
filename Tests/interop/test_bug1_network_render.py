"""BUG #1 regression — inbound thread renders via the Contacts→Network nav path.

BUG #1 was: a peer's chat thread showed **empty** when opened via the Contacts
→ Network tab path (Network announce row → NodeDetails → "Start Chat"), while
the same thread rendered correctly when opened via the Chats tab. It was first
seen on-device while Model B bring-up was degraded, and narrowed to a view/nav
issue (cross-process reads were proven fresh, so not a read-path bug).

Why both paths *should* render identically — the static case:
  * Inbound persistence keys the conversation on `message.sourceHash`
    (IncomingMessageHandler / AppServices) = the sender's lxmf.delivery
    destination hash.
  * The Network path builds a *fresh* `Conversation` from the announce:
    `ContactsView.startChat` → `Conversation(destinationHash: contact.identityHash …)`
    and `Contact.init(from: PathEntry)` sets `identityHash = entry.destinationHash`
    — i.e. the same lxmf.delivery destination hash.
  * Both nav paths therefore construct `MessagingViewModel(conversationHash:)`
    with the identical hash and `loadMessages` runs the same query.

This pins it empirically against the simulator (the nav/view code is
backend-independent, so the Python-backend sim reproduces it): Sideband sends a
text; we open the thread the BUG #1 way (Network tab) and assert the inbound
bubble renders, then via Chats as the control. Each open's `assertVisible: <body>`
is the render gate — an empty Network-tab thread (the BUG #1 symptom) fails the
first assertion.

Run with:
    cd Tests/interop
    ~/.reticulum-host/venv/bin/pytest -v test_bug1_network_render.py
"""

from __future__ import annotations
import re
import time

import pytest


def _wait_for_inbound(sim, *, content: str, timeout: float = 30.0) -> None:
    """Block until the inbound message for `content` is recorded, so both the
    Chats row and the Network→Start-Chat thread have it to load. Marker:
    `[RNS] inbound source=… content="…"` (was `[PY] inbound`; accept both)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for line in reversed(sim._tail_diag(800)):
            if ("[RNS] inbound source=" in line or "[PY] inbound source=" in line) and content in line:
                return
        time.sleep(0.4)
    pytest.fail(f"iOS didn't record inbound for {content!r} within {timeout}s")


def _peer_display_name(sim, sideband, *, timeout: float = 20.0) -> str:
    """The name iOS heard in Sideband's lxmf.delivery announce — the row label
    to tap in both the Network tab and Chats. Falls back to the same
    `Peer <HASH8>` form Columba shows for a nameless announce
    (`Contact.resolvedDisplayName`)."""
    pat = re.compile(
        rf'announce dest={sideband.identity_hex}\s+aspect=lxmf\.delivery\s+name="([^"]*)"'
    )
    deadline = time.time() + timeout
    while time.time() < deadline:
        for line in reversed(sim._tail_diag(800)):
            m = pat.search(line)
            if m:
                return m.group(1) or f"Peer {sideband.identity_hex[:8].upper()}"
        time.sleep(0.4)
    # No announce sighting cached this launch — fall back to the nameless form.
    return f"Peer {sideband.identity_hex[:8].upper()}"


def test_bug1_network_tab_renders_inbound_text(sim, sideband):
    """Sideband → iOS text; open the thread via Contacts→Network (the BUG #1
    path) and assert the inbound bubble renders, then via Chats as the control.

    The render assertion is `assertVisible: <body>` inside each Maestro flow —
    if the Network-tab thread came up empty (the BUG #1 symptom) the first
    assertion fails. We drive the Network path FIRST because its helper pops
    back to the tab root on exit, leaving the tab bar reachable for the Chats
    assertion."""
    body = f"bug1-net-{int(time.time()*1000)}"
    assert sideband.send_text(
        dest_hex=sim.lxmf_delivery_hex,
        content=body,
    ), "Sideband-side send_text returned False"

    _wait_for_inbound(sim, content=body)
    peer = _peer_display_name(sim, sideband)
    print(f"[BUG1] peer row label = {peer!r}", flush=True)

    # ── BUG #1 path: Contacts → Network → announce row → Start Chat. ──
    sim.assert_bubble_visible_via_network(
        peer_display_name=peer,
        content=body,
        screenshot="screenshots/bug1-network",
    )

    # ── Chats control path: Chats → conversation row → thread. ──
    # Tap the row by its message *preview* (== body), not its display name.
    # On the legacy Python/sim backend the conversation row's name is the
    # "Peer <hash>" fallback (persistInboundFromPython hardcodes it and the
    # announce-read stamp's isEmpty guard never corrects it), so it differs
    # from the Network tab's announce name. The preview is name-independent
    # and stays valid if that legacy-path naming is later fixed.
    sim.assert_bubble_visible(peer_display_name=body, content=body)
