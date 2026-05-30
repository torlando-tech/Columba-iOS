"""iOS-Columba ⇄ propagation-node interop: propagationSync count + non-blocking.

Pins two propagationSync behaviours against the live lxmd propagation node
(the harness already runs `rnsd -s` + `lxmd -p -s` on the host):

  * `test_propagation_sync_reports_received_count` — a peer queues a
    PROPAGATED message for iOS on the propagation node; after iOS syncs, the
    `propagationSync` result must report `received >= 1`. Pins the bug where
    `SwiftRNSBackend.propagationSync` hardcoded `receivedMessages: 0` so any
    "N new messages" UI always showed 0.

  * `test_propagation_sync_does_not_block_other_calls` — a sync against an
    unreachable node runs its full poll window; a concurrent `test-announce`
    must still execute promptly, not stall behind the sync. Pins the bug where
    the Python bridge ran propagation_sync on the serial GIL queue, blocking
    every other bridge call for the timeout.

Requires the same host setup as the rest of the suite (see README) plus a
reachable LXMF propagation node — auto-detected from iOS's announces, or set
`PROP_NODE_HEX` explicitly.
"""
from __future__ import annotations
import re
import time

import pytest


_RESULT_RE = re.compile(r"\[TEST-PROP-SYNC\] result ok=\w+ state=\S+ received=(\d+)")
_ERROR_RE = re.compile(r"\[TEST-PROP-SYNC\] error=(\S+)")


def _sync_once(sim, node: str, *, wait: float = 6.0):
    """Fire one test-prop-sync and return ('ok', received) | ('error', reason)
    | ('none', None) from the newest [TEST-PROP-SYNC] line."""
    before = sim.diag_log.stat().st_size if sim.diag_log.exists() else 0
    sim._open_url(f"lxma://test-prop-sync?node={node}")
    time.sleep(wait)
    for line in reversed(sim._read_diag_since(before)):
        m = _RESULT_RE.search(line)
        if m:
            return ("ok", int(m.group(1)))
        e = _ERROR_RE.search(line)
        if e:
            return ("error", e.group(1))
    return ("none", None)


def _sync_until_reachable(sim, node: str, *, deadline_s: float = 90.0) -> None:
    """Retry sync until the node path establishes. A just-reinstalled app
    hasn't heard the node's announce yet (lxmd announces only every ~5 min),
    so each attempt first primes the path: request_path makes the node emit a
    path-response/announce that propagates to the sim, giving it the node's
    identity + next hop."""
    import RNS  # the Sideband-peer fixture already initialised the shared instance
    node_bytes = bytes.fromhex(node)
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        try:
            if not RNS.Transport.has_path(node_bytes):
                RNS.Transport.request_path(node_bytes)
        except Exception:  # noqa: BLE001
            pass
        status, val = _sync_once(sim, node)
        last = (status, val)
        if status == "ok":
            return
        time.sleep(4)
    pytest.fail(f"propagation node {node} never became reachable (last={last})")


def test_propagation_sync_reports_received_count(sim, sideband):
    node = sim.auto_propagation_node_hex()
    if not node:
        pytest.skip("no propagation node heard; set PROP_NODE_HEX to lxmd's hash")

    # Warm up: establish the path + drain any backlog.
    _sync_until_reachable(sim, node)

    # Peer uploads a PROPAGATED message addressed to iOS's delivery dest.
    # Use send_with_fields (forces desired_method=PROPAGATED) rather than
    # send_text, whose method-selection prefers DIRECT when a delivery path
    # exists — the bootstrap creates one, so a "propagated" send_text would be
    # delivered directly and never reach the propagation node.
    content = f"prop-{int(time.time())}"
    assert sideband.send_with_fields(sim.lxmf_delivery_hex, content, {}, propagation=True), \
        "peer failed to enqueue the propagated message"
    time.sleep(15)  # let the upload settle on the node

    # Sync (retry past transient noPath); iOS should retrieve the queued
    # message and the result must report the real count, not a hardcoded 0.
    received = 0
    deadline = time.time() + 50.0
    while time.time() < deadline:
        status, n = _sync_once(sim, node)
        if status == "ok":
            received = n
            if received >= 1:
                break
        time.sleep(4)

    assert received >= 1, (
        f"propagationSync reported received={received}, expected >=1 "
        f"(the queued propagated message)"
    )


def test_propagation_sync_does_not_block_other_calls(sim):
    # Sync against an unreachable node: the bug (Python serial-queue) would
    # stall the bridge for the full 30s timeout; a healthy bridge lets a
    # concurrent announce run within a few seconds.
    before = sim.diag_log.stat().st_size if sim.diag_log.exists() else 0
    t0 = time.time()
    sim._open_url("lxma://test-prop-sync?node=ffffffffffffffffffffffffffffffff")
    sim._open_url("lxma://test-announce")

    announce_at = None
    deadline = time.time() + 20.0
    while time.time() < deadline:
        for line in sim._read_diag_since(before):
            if "[ANNOUNCE]" in line or "[AUTO_ANNOUNCE]" in line:
                announce_at = time.time() - t0
                break
        if announce_at is not None:
            break
        time.sleep(0.5)

    assert announce_at is not None, "announce never executed within 20s of the sync"
    assert announce_at < 10.0, (
        f"announce executed {announce_at:.1f}s after the sync started — it stalled "
        f"behind propagationSync's poll window (serial-queue blocking)"
    )
