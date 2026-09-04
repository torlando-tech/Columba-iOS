"""Durable E2E: a REAL incoming call over the shared lxmd mesh produces a
persistent, identity-scoped call-history row that renders in the Chats
**Voice** subtab (issue #167).

This is the load-bearing interop test for the iOS voice-call-history port.
Unlike the fixture-driven `test_voice.py` (which round-trips FIELD_AUDIO
payloads), this test drives a live `voice_caller.py` dial, so it exercises the
real transport + the app's `CallManager` write path end-to-end and asserts the
two things #167 actually ships:

  1. **Persistence** — the production App-Group GRDB store gains a
     `columba_call_history` row for the sim's own identity with
     `direction = incoming` and a terminal `outcome`.
  2. **UI** — Chats → Voice renders that row as a `call_history_card`;
     tapping it opens `call_history_details` with `call_history_call_again`.

Why the outcome is asserted as a *set*, not a single value: on the simulator,
CallKit auto-hangs-up a ringing incoming call before the UI answer tap can land,
so the observed terminal outcome is typically `declinedLocal` (or `missedIncoming`
if the caller lets the ring time out). Either is a correct, complete record —
the point is that the call was *recorded*, scoped to the right identity, and
rendered. A real answered call yields `connectedEnded`. All are valid; "no row"
or "wrong identity/direction" is the failure.

Run (Mac mini, on-boarded sim booted + Columba running, lxmd + rnsd up):
    cd Tests/interop
    ~/.reticulum-host/venv/bin/pytest -v test_voice_call_history.py

Prerequisites are the same session fixtures as the other interop tests
(`rnsd` + `lxmd` on the host, sim booted with Columba running). `voice_caller.py`
must be runnable with the RNS/LXMF venv (default `~/.reticulum-host/venv`).
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Optional

import pytest

HERE = Path(__file__).parent
# The headless caller shares the host lxmd (share_instance=Yes), so it needs the
# RNS/LXMF venv, not the test venv. Override with RNS_PYTHON if the layout differs.
RNS_PYTHON = os.environ.get("RNS_PYTHON", os.path.expanduser("~/.reticulum-host/venv/bin/python"))
CALLER = HERE / "voice_caller.py"
BUNDLE_ID = "network.columba.Columba"

# A ringing incoming call is recorded with a terminal outcome as soon as it ends.
# CallKit auto-hangup on the sim makes the exact value non-deterministic; these
# are all correct, complete records for a call that was received.
TERMINAL_OUTCOMES = {
    "connectedEnded",
    "missedIncoming",
    "declinedLocal",
    "rejectedRemote",
    "busyRemote",
    "cancelledLocal",
    "interrupted",
}

# How long to let the caller ring before it stops. Short (the row is written the
# moment the app's CallKit auto-hangup fires, which is well under this on the sim).
RING_SECONDS = 12


def _sh(cmd: list[str], timeout: float = 120.0) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _app_group_db(sim_container: Path, identity_hex: str) -> Path:
    """The App-Group GRDB store the app + Python runtime write to.

    Layout: <device>/data/Containers/Shared/AppGroup/<group>/Columba/
    python-<idhex>/lxmf-swift.db. `sim_container` is the app's data container
    (<device>/data/Containers/Data/Application/<appdir>), so the Shared tree
    sits three levels up, next to "Data". The group UUID varies per install,
    so glob it.
    """
    shared = sim_container.parent.parent.parent / "Shared" / "AppGroup"
    cands = list(shared.glob(f"*/Columba/python-{identity_hex}/lxmf-swift.db"))
    if not cands:
        pytest.fail(f"no App-Group lxmf-swift.db for identity {identity_hex} under {shared}")
    return cands[0]


def _history_rows(db: Path) -> list[tuple]:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        cols = [c[1] for c in con.execute("PRAGMA table_info(columba_call_history)")]
        want = ("direction", "local_identity_hash", "outcome", "call_attempt_id")
        idx = {k: cols.index(k) for k in want if k in cols}
        rows = con.execute("SELECT * FROM columba_call_history").fetchall()
    finally:
        con.close()
    if "direction" not in idx:
        return rows
    return [
        (
            r[idx["direction"]],
            r[idx["local_identity_hash"]],
            r[idx["outcome"]],
            r[idx["call_attempt_id"]],
        )
        for r in rows
    ]


def _incoming_rows(db: Path, identity_hex: str) -> list[tuple]:
    return [
        r
        for r in _history_rows(db)
        if r[0] == "incoming" and r[1] == identity_hex
    ]


def _hierarchy_texts(sim_udid: str, out: Path) -> list[str]:
    """Parse `maestro hierarchy` (JSON) into a flat list of visible texts.

    Newer Maestro emits JSON (a leading "None:" header line precedes the body).
    SwiftUI merges a card's label children into a single node's
    `accessibilityText`, so collect both `text` and `accessibilityText`.
    """
    env = dict(os.environ)
    env["MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED"] = "true"
    subprocess.run(
        ["maestro", "--device", sim_udid, "hierarchy"],
        stdout=open(out, "w"), stderr=subprocess.DEVNULL, timeout=90, env=env,
    )
    raw = out.read_text()
    data = json.loads(raw[raw.index("{"):])
    texts: list[str] = []

    def walk(n: dict) -> None:
        a = n.get("attributes", {})
        for key in ("text", "accessibilityText", "title"):
            v = a.get(key)
            if v:
                texts.append(v)
        for c in n.get("children", []):
            walk(c)

    walk(data)
    return texts


def test_real_incoming_call_produces_persistent_voice_history(
    sim, tmp_path,
):
    """Real mesh call → persistent row → Voice subtab renders it + details."""
    identity = sim.identity_hex
    db = _app_group_db(sim.container, identity)
    before = set(r[3] for r in _incoming_rows(db, identity))

    # 1) Drive a real incoming call (shares the host lxmd).
    assert CALLER.exists(), f"missing {CALLER}"
    assert os.access(RNS_PYTHON, os.X_OK), f"RNS python not executable: {RNS_PYTHON}"
    log = tmp_path / "caller.log"
    proc = subprocess.Popen(
        [RNS_PYTHON, str(CALLER), identity, str(RING_SECONDS)],
        stdout=open(log, "w"), stderr=subprocess.STDOUT, cwd=str(HERE),
    )

    # 2) Wait for a NEW incoming row scoped to the sim's identity, finalized
    #    (outcome set). beginCallAttempt writes the row in-flight (outcome NULL);
    #    recordEnd finalizes it when the call ends (CallKit auto-hangup on the
    #    sim fires within a couple seconds of the ring), so poll for the
    #    *finalized* row, not merely a new one.
    deadline = time.time() + 45
    new_row = None
    while time.time() < deadline:
        finalized = [
            r
            for r in _incoming_rows(db, identity)
            if r[3] not in before and r[2] in TERMINAL_OUTCOMES
        ]
        if finalized:
            new_row = finalized[0]
            break
        time.sleep(1)
    proc.wait(timeout=30)
    if new_row is None:
        # One last grace read after the caller exits (recordEnd is a Task).
        time.sleep(3)
        finalized = [
            r
            for r in _incoming_rows(db, identity)
            if r[3] not in before and r[2] in TERMINAL_OUTCOMES
        ]
        if finalized:
            new_row = finalized[0]

    caller_log = log.read_text()
    if new_row is None:
        pytest.fail(
            "no new incoming call-history row after a real call.\n"
            f"identity={identity}\ncaller_log tail:\n{caller_log[-1500:]}"
        )

    direction, local_id, outcome, attempt_id = new_row
    assert direction == "incoming", f"direction={direction!r}"
    assert local_id == identity, f"local_identity={local_id!r} != {identity!r}"
    assert outcome in TERMINAL_OUTCOMES, f"outcome={outcome!r}"

    # 3) The Voice subtab renders the row; tapping it opens details + call-again.
    #    The UI steps live in the committed flow (single source; CI re-runs it
    #    standalone once a row exists).
    flow = HERE / "flows" / "voice_call_history_ui.yaml"
    assert flow.exists(), f"missing {flow}"
    env = dict(os.environ)
    env["MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED"] = "true"
    r = subprocess.run(
        ["maestro", "--device", sim.udid, "test", str(flow)],
        capture_output=True, text=True, timeout=120, env=env,
    )
    if r.returncode != 0:
        pytest.fail(f"maestro voice_call_history_ui failed (rc={r.returncode}):\n{r.stdout}\n{r.stderr}")

    # 4) The card shows the caller's fallback name + a terminal outcome, and the
    #    details screen surfaces it. (Peer name is the "Peer <8 hex>" fallback
    #    since the headless caller has no text conversation.)
    out = tmp_path / "hier_details.json"
    texts = _hierarchy_texts(sim.udid, out)
    joined = "\n".join(texts)
    prefix = "Peer " + identity[:8].upper()
    # The *caller's* hash (not the sim's) is the peer — assert the outcome and
    # the details identifiers rather than guessing the caller's fallback name.
    assert "Incoming" in joined, "details should show the Incoming direction"
    assert any(o in joined for o in ("Declined", "Missed", "Connected", "Interrupted",
                                     "Failed", "Rejected", "Busy", "Cancelled")), \
        f"details should show a terminal outcome; texts={texts[:30]}"
