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


if __name__ == "__main__":
    unittest.main()
