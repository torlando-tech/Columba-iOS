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


def _peer_reach_node(node: str, *, deadline_s: float = 75.0) -> None:
    """Make the Sideband peer able to UPLOAD to lxmd: it must have heard lxmd's
    propagation announce (lxmd only announces every ~5 min), so request the path
    and wait until the peer can recall lxmd's identity + has a path. Without this
    the peer's PROPAGATED send has nowhere to go and lxmd never receives it."""
    import RNS
    node_bytes = bytes.fromhex(node)
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        if RNS.Transport.has_path(node_bytes) and RNS.Identity.recall(node_bytes) is not None:
            print(f"[PROP] peer can reach lxmd {node[:8]} (recall ok)", flush=True)
            return
        try:
            RNS.Transport.request_path(node_bytes)
        except Exception:  # noqa: BLE001
            pass
        time.sleep(3)
    pytest.fail(f"peer never heard lxmd's announce for {node} (cannot upload)")


def test_propagation_sync_reports_received_count(sim, sideband):
    node = sim.auto_propagation_node_hex()
    if not node:
        pytest.skip("no propagation node heard; set PROP_NODE_HEX to lxmd's hash")

    # Step 3: both sides must hear lxmd's announce before they can use it.
    _peer_reach_node(node)            # peer side (upload path)
    # Step 4 (peer): (re)set the peer's outbound propagation node now that lxmd
    # is reachable. The fixture set it in start() before the path existed (and
    # swallows that failure), leaving the router's outbound_propagation_node
    # unset → a PROPAGATED send would have nowhere to upload.
    import RNS  # noqa: F401
    sideband._core.set_active_propagation_node(bytes.fromhex(node))
    time.sleep(2)
    _sync_until_reachable(sim, node)  # sim side (sync path) + drain backlog

    # Step 5: peer uploads a PROPAGATED message addressed to iOS's delivery dest.
    # Use send_with_fields (forces desired_method=PROPAGATED) rather than
    # send_text, whose method-selection prefers DIRECT when a delivery path
    # exists — the bootstrap creates one, so a "propagated" send_text would be
    # delivered directly and never reach the propagation node.
    content = f"prop-{int(time.time())}"
    assert sideband.send_with_fields(sim.lxmf_delivery_hex, content, {}, propagation=True), \
        "peer failed to enqueue the propagated message"
    time.sleep(18)  # let the upload link to lxmd establish + transfer

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


_CONCURRENCY_RE = re.compile(r"\[TEST-CONCURRENCY\] announce_ms=(\d+) ok=\w+ sync_ms=(\d+)")


def test_propagation_sync_does_not_block_other_calls(sim):
    # In-process concurrency probe (lxma://test-concurrency-probe): the app sets
    # an unreachable propagation node, launches a propagationSync WITHOUT
    # awaiting it, waits until it's mid-poll, then times how long a concurrent
    # announce takes to complete. The bug (the Python bridge ran the blocking
    # sync on its serial queue) stalls the announce for the sync's whole
    # path-request window (~seconds); the fix (sync on a dedicated queue, the
    # Python poll releasing the GIL between iterations) lets the announce return
    # promptly. The whole thing is measured in-process, so — unlike firing two
    # separate `lxma://` URLs — it carries no Maestro-dispatch latency, and the
    # fixed vs buggy builds are cleanly separable (~100ms vs ~8s).
    before = sim.diag_log.stat().st_size if sim.diag_log.exists() else 0
    sim._open_url("lxma://test-concurrency-probe")

    announce_ms = sync_ms = None
    deadline = time.time() + 45.0
    while time.time() < deadline and announce_ms is None:
        for line in sim._read_diag_since(before):
            m = _CONCURRENCY_RE.search(line)
            if m:
                announce_ms, sync_ms = int(m.group(1)), int(m.group(2))
                break
        time.sleep(1.0)

    assert announce_ms is not None, "concurrency probe never logged a result"
    assert announce_ms < 3000, (
        f"a concurrent announce took {announce_ms}ms while a propagationSync "
        f"was in flight (sync_ms={sync_ms}) — it stalled behind the sync "
        f"(serial-queue blocking)"
    )
