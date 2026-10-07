"""P1 #2 (ne-python-architecture-review): an identity switch must rebind the
durable inbox + GRDB store connections.

Bug: `_set_inbox_path` / `_set_grdb_store` set the new per-identity path and then
call `_open_inbox()` / `_open_grdb()`. But both openers early-return when a
connection already exists, so after an in-NE identity switch (A -> B, same process)
the module keeps holding identity A's SQLite connection and writes identity B's
durable events into A's database. This is a silent cross-identity data leak.

These tests load the persistence functions out of `app/rns_bridge.py` in an
isolated namespace (the module has iOS-only top-level side effects, e.g. it
replaces `sys.stdout`, so the whole module cannot be imported here - same pattern
as `test_async_propagation_fallback.py`). They assert against rows in REAL temp
files opened by an independent connection, not against the internals.
"""

import ast
import json
import os
import shutil
import sqlite3
import sys
import threading
import time
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"

_INBOX_TABLE = """CREATE TABLE IF NOT EXISTS ne_inbox (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at REAL NOT NULL
)"""


def _extract(names):
    tree = ast.parse(BRIDGE.read_text())
    wanted = set(names)
    return [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in wanted]


class RnsBridgePersistenceTest(unittest.TestCase):
    """Identity switch must rebind the durable inbox/GRDB connections."""

    def setUp(self):
        self._fresh()

    def _fresh(self):
        """Build a clean namespace for the persistence functions."""
        ns = {
            "Any": object,
            "os": __import__("os"),
            "sqlite3": sqlite3,
            "json": json,
            "time": time,
            "threading": threading,
            "RNS": types.SimpleNamespace(
                log=lambda *a, **k: None,
                LOG_ERROR=0,
            ),
            "_inbox_path": None,
            "_inbox_conn": None,
            "_inbox_bound_path": None,
            "_inbox_lock": threading.Lock(),
            "_durable_mode": False,
            "_grdb_path": None,
            "_grdb_conn": None,
            "_grdb_bound_path": None,
            "_grdb_lock": threading.Lock(),
            "_coalesced_events_ping": lambda: None,
            "_post_link_events_ping": lambda: None,
        }
        exec(
            compile(
                ast.Module(body=_extract([
                    "_set_inbox_path", "_open_inbox",
                    "_set_grdb_store", "_open_grdb",
                    "_publish_durable", "_put",
                ]), type_ignores=[]),
                str(BRIDGE),
                "exec",
            ),
            ns,
        )
        self.ns = ns

    # -- real-file helper ------------------------------------------------

    def _create_store(self, path):
        """Create the ne_inbox table in a real file (independent connection)."""
        conn = sqlite3.connect(str(path))
        try:
            conn.execute(_INBOX_TABLE)
            conn.commit()
        finally:
            conn.close()

    def _inbox_count(self, path):
        conn = sqlite3.connect(str(path))
        try:
            conn.execute(_INBOX_TABLE)
            cur = conn.execute("SELECT COUNT(*) FROM ne_inbox")
            return cur.fetchone()[0]
        finally:
            conn.close()

    # -- inbox: write lands in the file the path currently points at -----

    def test_inbox_write_lands_in_current_path(self):
        a = self._test_dir() / "a.db"
        b = self._test_dir() / "b.db"
        self._create_store(a)
        self._create_store(b)

        self.ns["_set_inbox_path"](str(a))
        self.ns["_put"]("state", note="at-a")

        self.assertEqual(1, self._inbox_count(a), "write should land in A while pointed at A")
        self.assertEqual(0, self._inbox_count(b), "B should be empty while pointed at A")

    def test_inbox_path_switch_rebinds_to_new_file(self):
        """Switching the path to B must move subsequent writes to B, not A."""
        a = self._test_dir() / "a.db"
        b = self._test_dir() / "b.db"
        self._create_store(a)
        self._create_store(b)

        self.ns["_set_inbox_path"](str(a))
        self.ns["_put"]("state", note="at-a")
        self.assertEqual(1, self._inbox_count(a))

        # In-NE identity switch: point the same running module at B.
        self.ns["_set_inbox_path"](str(b))
        self.ns["_put"]("state", note="at-b")

        self.assertEqual(
            1, self._inbox_count(b),
            "after switching to B, the write must land in B's store",
        )
        self.assertEqual(
            1, self._inbox_count(a),
            "A must NOT receive B's write (would be a cross-identity leak)",
        )

    def test_open_inbox_rebinds_when_path_changes(self):
        """`_open_inbox` must reopen when the path changed, not keep the old conn."""
        a = self._test_dir() / "a.db"
        b = self._test_dir() / "b.db"
        self._create_store(a)
        self._create_store(b)

        self.ns["_inbox_path"] = str(a)
        self.ns["_open_inbox"]()
        self.assertIsNotNone(self.ns["_inbox_conn"], "should open a conn at A")

        # Simulate the path being repointed (as _set_inbox_path does) then a re-open.
        self.ns["_inbox_path"] = str(b)
        self.ns["_open_inbox"]()

        # The live connection must now target B: writing through it lands in B.
        with self.ns["_inbox_lock"]:
            self.ns["_inbox_conn"].execute(
                "INSERT INTO ne_inbox (kind, payload, created_at) VALUES (?, ?, ?)",
                ("state", json.dumps({"t": time.time()}), time.time()),
            )
            self.ns["_inbox_conn"].commit()

        self.assertEqual(
            1, self._inbox_count(b),
            "the re-opened connection must write to B, not the stale A",
        )
        self.assertEqual(0, self._inbox_count(a))

    # -- grdb: same rebind discipline ------------------------------------

    def test_grdb_path_switch_rebinds_to_new_file(self):
        """The GRDB store must rebind on a path switch, mirroring the inbox fix."""
        a = self._test_dir() / "grdb_a.db"
        b = self._test_dir() / "grdb_b.db"
        self._create_grdb_store(a)
        self._create_grdb_store(b)

        self.ns["_set_grdb_store"](str(a))
        self.assertIsNotNone(self.ns["_grdb_conn"], "should open a GRDB conn at A")

        self.ns["_set_grdb_store"](str(b))

        # The live GRDB connection must now target B.
        with self.ns["_grdb_lock"]:
            self.ns["_grdb_conn"].execute(
                "INSERT INTO messages (message_id, packed) VALUES (?, ?)",
                (b"mid-b", b"packed-b"),
            )
            self.ns["_grdb_conn"].commit()

        self.assertEqual(
            1, self._grdb_count(b),
            "after switching the GRDB store to B, writes must land in B",
        )
        self.assertEqual(
            0, self._grdb_count(a),
            "A must NOT receive B's write (cross-identity GRDB leak)",
        )

    # -- grdb real-file helpers -----------------------------------------

    def _create_grdb_store(self, path):
        conn = sqlite3.connect(str(path))
        try:
            conn.execute("CREATE TABLE IF NOT EXISTS messages (message_id BLOB, packed BLOB)")
            conn.execute("CREATE TABLE IF NOT EXISTS conversations (is_pinned INTEGER NOT NULL DEFAULT 0)")
            conn.commit()
        finally:
            conn.close()

    def _grdb_count(self, path):
        conn = sqlite3.connect(str(path))
        try:
            conn.execute("CREATE TABLE IF NOT EXISTS messages (message_id BLOB, packed BLOB)")
            cur = conn.execute("SELECT COUNT(*) FROM messages")
            return cur.fetchone()[0]
        finally:
            conn.close()

    # -- temp dir helper --------------------------------------------------

    def _test_dir(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="rns_persist_"))
        self.addCleanup(self._rmtree, d)
        return d

    @staticmethod
    def _rmtree(d):
        import shutil
        shutil.rmtree(d, ignore_errors=True)


class RnsBridgeStartPersistenceModeTest(unittest.TestCase):
    """P1 #1 (ne-python-architecture-review): the shipping backend must not
    enter NE-only durable mode.

    `start()` currently calls `_set_inbox_path` unconditionally, which flips
    `_durable_mode = True`. The shipping (in-process) backend runs Python in the
    app process with a process-local config dir and no `ModelBInboundReplay`, so
    forcing durable mode there can lose inbound or bypass field/UI processing.
    Persistence must be an explicit opt-in (the NE passes it; shipping does not).

    These tests drive the real `start()` through its persistence-wiring section:
    the stubbed `RNS.Reticulum` raises a sentinel, which `start`'s `finally`
    restores `signal.signal` on, and which stops the run before any identity or
    router work. We then assert on `_durable_mode` + the inbox path globals.
    """

    _PERSIST_FN_NAMES = [
        "start",
        "_set_inbox_path", "_open_inbox",
        "_set_grdb_store", "_open_grdb",
    ]

    class _StopAfterPersistence(Exception):
        """Sentinel raised by the stubbed RNS.Reticulum to stop start() right
        after the persistence globals are wired."""

    def _build(self):
        ns = {
            "Any": object,
            "os": __import__("os"),
            "sqlite3": sqlite3,
            "json": json,
            "time": time,
            "threading": threading,
            "RNS": types.SimpleNamespace(
                log=lambda *a, **k: None,
                LOG_ERROR=0,
                Reticulum=lambda *a, **k: (_ for _ in ()).throw(
                    self._StopAfterPersistence()
                ),
            ),
            "_lock": threading.Lock(),
            "_state": {
                "started": False,
                "reticulum": None,
                "router": None,
                "identity": None,
                "destination": None,
                "handler": None,
                "config_dir": None,
            },
            "_inbox_path": None,
            "_inbox_conn": None,
            "_inbox_bound_path": None,
            "_inbox_lock": threading.Lock(),
            "_durable_mode": False,
            "_grdb_path": None,
            "_grdb_conn": None,
            "_grdb_bound_path": None,
            "_grdb_lock": threading.Lock(),
            "_coalesced_events_ping": lambda: None,
            "_post_link_events_ping": lambda: None,
            "_local_info": lambda: {},
            "_uninstall_native_stamp_generator": lambda: None,
        }
        exec(
            compile(
                ast.Module(
                    body=_extract(self._PERSIST_FN_NAMES), type_ignores=[]
                ),
                str(BRIDGE),
                "exec",
            ),
            ns,
        )
        return ns

    def test_start_default_keeps_inprocess_mode(self):
        ns = self._build()
        cfg = self._temp_config_dir()
        with self.assertRaises(self._StopAfterPersistence):
            ns["start"](
                config_dir=str(cfg),
                identity_path=str(cfg / "identity"),
                display_name="host",
            )
        self.assertFalse(
            ns["_durable_mode"],
            "default (shipping) start must NOT enter NE-only durable mode",
        )
        self.assertIsNone(
            ns["_inbox_path"],
            "default start must not point the durable inbox at a store",
        )
        self.assertIsNone(
            ns["_grdb_path"],
            "default start must not point the GRDB store at a file",
        )

    def test_start_ne_mode_enables_durable(self):
        ns = self._build()
        cfg = self._temp_config_dir()
        with self.assertRaises(self._StopAfterPersistence):
            ns["start"](
                config_dir=str(cfg),
                identity_path=str(cfg / "identity"),
                display_name="host",
                host_persistence="ne",
            )
        self.assertTrue(
            ns["_durable_mode"],
            "NE host_persistence must enable durable mode",
        )
        self.assertEqual(
            str(cfg / "ne-inbox.db"),
            ns["_inbox_path"],
            "NE mode must point the inbox at <config_dir>/ne-inbox.db",
        )
        self.assertEqual(
            str(cfg / "lxmf-swift.db"),
            ns["_grdb_path"],
            "NE mode must point the GRDB store at <config_dir>/lxmf-swift.db",
        )

    def _temp_config_dir(self):
        import tempfile

        d = Path(tempfile.mkdtemp(prefix="rns_start_cfg_"))
        self.addCleanup(self._rmtree, d)
        return d

    @staticmethod
    def _rmtree(d):
        import shutil

        shutil.rmtree(d, ignore_errors=True)


class RnsBridgeIngressRetryTest(unittest.TestCase):
    """P1 #4 (ne-python-architecture-review): a failed inbound GRDB write must
    not permanently drop the accepted message.

    The legacy `_delivery_callback` failure branch logged "message lost until the
    peer re-sends" and returned, dropping the content. The real failure mode: the
    NE sets `_grdb_path` to the shared dir, but the app hasn't launched / migrated
    the store file yet, so `_open_grdb`'s isfile guard leaves the connection None
    and the write fails. The fix retains the raw artifact durably in a NE-owned
    JSONL file (`ingress-retry.jsonl`, next to the store) and re-projects it into
    the store as soon as the store file is reachable again. The file is NE-owned
    (the app's `drain_inbox` never touches it) and the projection is idempotent
    (INSERT OR REPLACE by message_id), so a retried message is not double-inserted.
    """

    _FN_NAMES = [
        "_write_inbound_to_grdb",
        "_write_inbound_to_grdb_impl",
        "_open_grdb",
        "_is_telemetry_only_inbound",
        "_ingress_retry_path",
        "_ingress_retry_fields",
        "_store_ingress_retry_artifact",
        "_reconstruct_ingress_message",
        "_retry_pending_ingress",
    ]

    def _build(self):
        ns = {
            "Any": object,
            "os": __import__("os"),
            "sqlite3": sqlite3,
            "json": json,
            "time": time,
            "threading": threading,
            "types": types,
            "RNS": types.SimpleNamespace(log=lambda *a, **k: None, LOG_ERROR=0, LOG_DEBUG=1),
            "_grdb_path": None,
            "_grdb_conn": None,
            "_grdb_bound_path": None,
            "_grdb_lock": threading.Lock(),
            "_GRDB_STATE_DELIVERED": 0x08,
            "_ingress_retry_lock": threading.Lock(),
            "_retrying_ingress": False,
        }
        exec(
            compile(ast.Module(body=_extract(self._FN_NAMES), type_ignores=[]), str(BRIDGE), "exec"),
            ns,
        )
        return ns

    def _msg(self, *, src: bytes = b"aa" * 32, dst: bytes = b"bb" * 32, content: bytes = b"hello"):
        return types.SimpleNamespace(
            hash=b"cc" * 32,
            source_hash=src,
            destination_hash=dst,
            title=b"t",
            content=content,
            signature=b"sig",
            stamp=None,
            timestamp=1234.0,
            method=4,
            rssi=None,
            snr=None,
            q=None,
            packed=b"\x01\x02\x03packed-lxmf-wire",
        )

    def _artifact_lines(self, ns):
        path = ns["_ingress_retry_path"]()
        if path is None or not os.path.isfile(path):
            return []
        with open(path, "r", encoding="utf-8") as fh:
            return [line for line in fh.read().splitlines() if line.strip()]

    def test_failed_grdb_write_retains_artifact_durable(self):
        ns = self._build()
        store_dir = self._dir()
        store = store_dir / "lxmf-swift.db"
        # NE points at the shared dir, but the app has not created the store yet.
        ns["_grdb_path"] = str(store)

        self.assertFalse(
            ns["_write_inbound_to_grdb"](self._msg()),
            "the GRDB write must fail while the store file is absent",
        )
        lines = self._artifact_lines(ns)
        self.assertEqual(1, len(lines),
                         "a failed GRDB write must retain a durable artifact (not drop the message)")
        payload = json.loads(lines[0])
        self.assertEqual(b"\x01\x02\x03packed-lxmf-wire", bytes.fromhex(payload["packed_hex"]),
                         "the retained artifact must carry the raw packed wire for re-projection")

    def test_retry_projects_into_store_and_clears_artifact(self):
        ns = self._build()
        store_dir = self._dir()
        store = store_dir / "lxmf-swift.db"
        self._make_grdb(store)  # app has now launched + created the store
        ns["_grdb_path"] = str(store)

        # 1) First write before the store existed would have failed; here we
        #    pre-seed the artifact to simulate that earlier failed delivery.
        self._store_artifact_directly(ns, self._msg())
        self.assertEqual(1, len(self._artifact_lines(ns)))

        # 2) Store is now reachable -> retry projects the artifact into it.
        projected = ns["_retry_pending_ingress"]()
        self.assertGreaterEqual(projected, 1, "retry must project the retained artifact into the store")
        self.assertEqual(0, len(self._artifact_lines(ns)),
                         "a successfully projected artifact must be cleared from the file")
        self.assertEqual(1, self._grdb_message_count(store),
                         "the message must land in the GRDB store, not be lost")

    def test_retry_is_idempotent(self):
        """Re-running the retry must not double-insert an already-projected row."""
        ns = self._build()
        store_dir = self._dir()
        store = store_dir / "lxmf-swift.db"
        self._make_grdb(store)
        ns["_grdb_path"] = str(store)
        self._store_artifact_directly(ns, self._msg())

        ns["_retry_pending_ingress"]()
        first = self._grdb_message_count(store)
        self.assertEqual(1, first)
        # No artifacts remain, so a second retry is a no-op.
        ns["_retry_pending_ingress"]()
        self.assertEqual(1, self._grdb_message_count(store),
                         "a retried message must be projected exactly once (idempotent)")

    def _store_artifact_directly(self, ns, message):
        fields = ns["_ingress_retry_fields"](message)
        self.assertIsNotNone(fields)
        ns["_store_ingress_retry_artifact"](fields)

    def _make_grdb(self, path):
        conn = sqlite3.connect(str(path))
        try:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS messages ("
                " message_id BLOB, conversation_hash BLOB, destination_hash BLOB,"
                " source_hash BLOB, signature BLOB, timestamp REAL, title BLOB, content BLOB,"
                " fields BLOB, stamp BLOB, state INTEGER, method INTEGER, delivery_attempts INTEGER,"
                " progress REAL, incoming INTEGER, rssi REAL, snr REAL, q REAL, ratchet_id BLOB,"
                " packed_lxmf BLOB, receiving_interface TEXT, reply_to_id BLOB,"
                " reactions_json TEXT, created_at REAL, updated_at REAL)"
            )
            conn.execute(
                "CREATE TABLE IF NOT EXISTS conversations ("
                " destination_hash BLOB, display_name TEXT, last_message_timestamp REAL,"
                " last_message_preview TEXT, unread_count INTEGER, is_unread INTEGER,"
                " is_favorite INTEGER, icon_name TEXT, icon_fg_color TEXT, icon_bg_color TEXT,"
                " created_at REAL, updated_at REAL, is_pinned INTEGER NOT NULL DEFAULT 0)"
            )
            conn.commit()
        finally:
            conn.close()

    def _grdb_message_count(self, path):
        conn = sqlite3.connect(str(path))
        try:
            return conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        finally:
            conn.close()

    def _dir(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="rns_ingress_"))
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        return d


class RnsBridgeInboxDrainTest(unittest.TestCase):
    """Spec #5: durable events must not be deleted on read.

    Bug: `drain_inbox` read + `DELETE FROM ne_inbox` the whole table, so a lost
    IPC reply (or app termination before the drain reply is processed) loses
    delivery-state updates and announces permanently. The review (Contract §5)
    requires bounded reads + an explicit ack/cursor advance AFTER the consumer
    processes the rows.

    These tests assert against REAL temp files via an independent connection:
    - `drain_inbox` reads but does NOT delete (the rows survive the read).
    - `drain_inbox` returns each row's `seq` so the consumer can ack precisely.
    - `ack_inbox(max_seq)` deletes only rows at or below the ack'd cursor,
      leaving newer (not-yet-acked) rows intact.
    """

    def setUp(self):
        self._fresh()

    def _fresh(self):
        ns = {
            "Any": object,
            "os": __import__("os"),
            "sqlite3": sqlite3,
            "json": json,
            "time": time,
            "threading": threading,
            "RNS": types.SimpleNamespace(
                log=lambda *a, **k: None,
                LOG_ERROR=0,
            ),
            "_inbox_path": None,
            "_inbox_conn": None,
            "_inbox_bound_path": None,
            "_inbox_lock": threading.Lock(),
            "_durable_mode": False,
            "_coalesced_events_ping": lambda: None,
            "_post_link_events_ping": lambda: None,
        }
        exec(
            compile(
                ast.Module(body=_extract([
                    "_set_inbox_path", "_open_inbox",
                    "_publish_durable", "_put",
                    "drain_inbox", "ack_inbox",
                ]), type_ignores=[]),
                str(BRIDGE),
                "exec",
            ),
            ns,
        )
        self.ns = ns

    def _create_store(self, path):
        conn = sqlite3.connect(str(path))
        try:
            conn.execute(_INBOX_TABLE)
            conn.commit()
        finally:
            conn.close()

    def _inbox_count(self, path):
        conn = sqlite3.connect(str(path))
        try:
            conn.execute(_INBOX_TABLE)
            return conn.execute("SELECT COUNT(*) FROM ne_inbox").fetchone()[0]
        finally:
            conn.close()

    def _dir(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="rns_inbox_drain_"))
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        return d

    def _point_at(self, path):
        self._create_store(path)
        self.ns["_set_inbox_path"](str(path))

    def test_drain_inbox_does_not_delete(self):
        """Reading the inbox must NOT delete rows (bounded read)."""
        p = self._dir() / "inbox.db"
        self._point_at(p)
        self.ns["_put"]("state", note="e1")
        self.ns["_put"]("delivery", note="e2")
        self.assertEqual(2, self._inbox_count(p))

        events = self.ns["drain_inbox"]()
        self.assertEqual(2, len(events), "drain must return both events")

        # The read must NOT have cleared the table: a lost reply / app death
        # before the consumer acks must not lose the events.
        self.assertEqual(
            2, self._inbox_count(p),
            "drain_inbox must be a bounded read; rows survive until ack_inbox",
        )

    def test_drain_inbox_carries_seq(self):
        """Each drained event carries its `seq` so the consumer can ack it."""
        p = self._dir() / "inbox.db"
        self._point_at(p)
        self.ns["_put"]("state", note="first")
        self.ns["_put"]("state", note="second")

        events = self.ns["drain_inbox"]()
        self.assertEqual(2, len(events))
        self.assertIn("seq", events[0], "drained event must carry its seq")
        self.assertIn("seq", events[1], "drained event must carry its seq")
        self.assertLess(events[0]["seq"], events[1]["seq"], "oldest-first seq order")

    def test_ack_inbox_deletes_only_below_cursor(self):
        """ack_inbox(max_seq) deletes rows at/below the cursor, keeps newer."""
        p = self._dir() / "inbox.db"
        self._point_at(p)
        self.ns["_put"]("state", note="a")
        self.ns["_put"]("state", note="b")
        self.ns["_put"]("state", note="c")

        events = self.ns["drain_inbox"]()
        self.assertEqual(3, len(events))
        seq_b = events[1]["seq"]  # ack through the middle row

        self.ns["ack_inbox"](seq_b)
        self.assertEqual(
            1, self._inbox_count(p),
            "only rows at/below the ack'd cursor are deleted; the newest survives",
        )

    def test_ack_inbox_is_idempotent_and_safe_below_floor(self):
        """A second ack at the same / a lower cursor deletes nothing new."""
        p = self._dir() / "inbox.db"
        self._point_at(p)
        self.ns["_put"]("state", note="a")
        self.ns["_put"]("state", note="b")

        events = self.ns["drain_inbox"]()
        seq_a = events[0]["seq"]
        self.ns["ack_inbox"](seq_a)
        self.assertEqual(1, self._inbox_count(p))

        # Re-ack at the same cursor: no-op (row already gone), count unchanged.
        self.ns["ack_inbox"](seq_a)
        self.assertEqual(1, self._inbox_count(p))

    def test_drain_after_ack_returns_only_unacked(self):
        """After an ack, a re-drain returns only the still-unacked rows."""
        p = self._dir() / "inbox.db"
        self._point_at(p)
        self.ns["_put"]("state", note="a")
        self.ns["_put"]("state", note="b")

        first = self.ns["drain_inbox"]()
        self.assertEqual(2, len(first))
        self.ns["ack_inbox"](first[0]["seq"])

        second = self.ns["drain_inbox"]()
        self.assertEqual(1, len(second), "only the unacked row is re-returned")
        self.assertEqual("b", second[0].get("note"))


if __name__ == "__main__":
    unittest.main()