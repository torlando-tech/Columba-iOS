"""Standalone real-RNS check for PythonRNSNodeEngine (Mac venv only).

Drives the adapter against the REAL ``app.rns_bridge`` with real RNS + LXMF and
prints a PASS/FAIL verdict. Unlike the unittest form, it ends with an explicit
``os._exit`` after the assertions: real RNS spawns daemon threads (delayed
re-announce, native stamp generator) that do not settle cleanly under a bare
``unittest`` process exit, so a script that asserts-then-``os._exit(0)`` is the
honest "the adapter drives real RNS" gate.

It runs ONLY where RNS is importable (the Mac ``~/.reticulum-host/venv``). On a
machine without RNS it prints SKIP and exits 0.

    ~/.reticulum-host/venv/bin/python engine/columba_node/scripts/real_rns_check.py
"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(__file__)
REPO_ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

try:
    import RNS  # noqa: F401
except Exception as e:
    print(f"SKIP: RNS not importable here ({e}); run in the Mac RNS venv")
    os._exit(0)


def _submit_intent(destination: str) -> dict:
    return {
        "commandID": "44444444-4444-4444-8444-444444444444",
        "body": {
            "tag": "submitMessage",
            "value": {
                "scope": {"identityID": "33333333-3333-4333-8333-333333333333"},
                "destination": destination,
                "payload": {
                    "tag": "chat",
                    "value": {
                        "title": {"tag": "inline", "value": ""},
                        "content": {"tag": "inline", "value": "hi"},
                        "attachments": [], "reply": None,
                        "appearance": None, "extensions": None,
                    },
                },
                "delivery": {"preferred": "automatic",
                             "allowPropagationFallback": False,
                             "maxAttempts": 1, "stampBudgetMs": 5000},
                "deadline": 1790086400000,
            },
        },
    }


def main() -> int:
    import tempfile
    import shutil

    from app import rns_bridge
    from engine.columba_node.engine import PythonRNSNodeEngine

    tmp = tempfile.mkdtemp(prefix="columba-node-check-")
    config_dir = os.path.join(tmp, "config")
    identity_path = os.path.join(tmp, "identity")

    engine = PythonRNSNodeEngine(
        rns_bridge, config_dir, identity_path=identity_path,
        display_name="ColumbaNodeRealCheck",
    )

    # 1. start -> real RNS boot, ready descriptor with a real identity hash.
    desc = engine.start("11111111-1111-4111-8111-111111111111")
    rt = desc["runtime"]
    assert rt["phase"] == "ready", f"phase {rt['phase']}"
    assert rt["actualEnabled"] is True
    ids = rt["enabledIdentities"]
    # RNS identity.hash is 16 bytes = 32 hex chars (NOT 64; that's a destination
    # hash). The transport identity carried in enabledIdentities is the identity hash.
    assert len(ids) == 1 and len(ids[0]) == 32, f"identity {ids}"
    assert ids[0].lower().strip("0123456789abcdef") == "", f"not hex: {ids[0]}"
    assert desc["storeSchema"] == 1
    assert desc["version"] == {"major": 1, "minor": 0}
    caps = {c["feature"]: c["support"] for c in desc["capabilities"]}
    assert caps.get("durableMessaging") == "supported", caps
    print(f"OK  start: phase=ready identity={ids[0][:12]}… caps durs={caps['durableMessaging']}")

    # 2. can_execute gate: submitMessage allowed once started.
    assert engine.can_execute(_submit_intent("cc" * 32)) is None
    print("OK  can_execute(submitMessage) -> None (allowed)")

    # 3. execute a malformed destination -> real bridge returns bad-hash ->
    #    adapter maps to invalidArgument.
    res = engine.execute(_submit_intent("nothex"))
    assert res["ok"] is False
    assert res["error"]["code"] == "invalidArgument", res
    assert res["error"]["field"] == "destination"
    print("OK  execute(bad-hash) -> invalidArgument/destination")

    # 4. stop is idempotent.
    engine.stop()
    engine.stop()
    rt2 = engine.runtime_snapshot()
    assert rt2["phase"] == "stopped", rt2
    print("OK  stop: idempotent, phase=stopped")

    shutil.rmtree(tmp, ignore_errors=True)
    print("PASS: adapter drives real RNS (boot, gate, execute mapping, stop)")
    return 0


if __name__ == "__main__":
    try:
        rc = main()
    except AssertionError as e:
        print(f"FAIL: {e}")
        rc = 1
    # Explicit exit: real RNS daemon threads do not settle under a normal
    # process exit in this headless context; the assertions above are the gate.
    os._exit(rc)
