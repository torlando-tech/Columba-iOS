"""Exercise the real inbox functions with SQLite, without loading iOS/RNS.

Only the named functions/constants are extracted; their SQL and replay logic run
unchanged. Run: python3 -m unittest Tests.static.test_rns_bridge_inbox
"""
import ast
import json
import sqlite3
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any


class InboxReplayTests(unittest.TestCase):
    def setUp(self):
        source = ast.parse((Path(__file__).resolve().parents[2] / 'app/rns_bridge.py').read_text())
        names = {'drain_inbox', 'ack_inbox', '_quarantine_inbox_event'}
        nodes = [n for n in source.body if
                 isinstance(n, ast.FunctionDef) and n.name in names or
                 isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id.startswith('_INBOX_BATCH_') for t in n.targets)]
        self.db = sqlite3.connect(':memory:')
        self.db.execute('CREATE TABLE ne_inbox(seq INTEGER PRIMARY KEY, kind TEXT, payload TEXT, created_at REAL)')
        self.ns = dict(json=json, time=__import__('time'), _inbox_lock=threading.RLock(),
                       _open_inbox=lambda: None, _inbox_conn=self.db,
                       RNS=SimpleNamespace(log=lambda *args: None, LOG_ERROR=1, LOG_WARNING=2))
        exec(compile(ast.Module(body=nodes, type_ignores=[]), 'rns_bridge.py', 'exec'), self.ns)
        self.addCleanup(self.db.close)

    def add(self, payload, kind='announce'):
        self.db.execute('INSERT INTO ne_inbox(kind,payload,created_at) VALUES(?,?,0)', (kind, payload))
        self.db.commit()

    def drain(self):
        return self.ns['drain_inbox']()

    def test_overnight_backlog_is_bounded_and_drains_in_order(self):
        for i in range(12604):
            self.add(json.dumps(dict(kind='announce', t=i, destination_hash=str(i))))
        seen = []
        while batch := self.drain():
            self.assertLessEqual(len(batch), 128)
            self.assertLessEqual(len(json.dumps(batch).encode()), 256 * 1024)
            self.assertEqual(batch, self.drain(), 'read must not advance the cursor')
            seen.extend(e['seq'] for e in batch)
            self.assertTrue(self.ns['ack_inbox'](batch[-1]['seq']))
        self.assertEqual(seen, list(range(1,12605)))

    def test_byte_budget_splits_batch_before_row_limit(self):
        for i in range(40):
            self.add(json.dumps(dict(kind='inbound', t=i, content='x' * 20000)))
        batch = self.drain()
        self.assertLess(len(batch), 40)
        self.assertLessEqual(len(json.dumps(batch).encode()), 256 * 1024)

    def test_escaped_unicode_counts_as_wire_bytes(self):
        for i in range(40):
            self.add(json.dumps(dict(kind='inbound', t=i, content='😀' * 1000), ensure_ascii=False))
        self.assertLessEqual(len(json.dumps(self.drain()).encode()), 256 * 1024)

    def test_poison_rows_are_preserved_and_do_not_block_following_events(self):
        for raw in ('{bad', '[]', json.dumps(dict(kind='inbound', t=0, content='x' * 300000))):
            self.add(raw)
        self.add(json.dumps(dict(kind='announce', t=1)))
        batch = self.drain()
        self.assertEqual([e['seq'] for e in batch], [1,2,3,4])
        self.assertEqual([e['kind'] for e in batch], ['inbox_error'] * 3 + ['announce'])
        self.assertEqual(self.db.execute('SELECT count(*) FROM ne_inbox').fetchone()[0], 4)
        self.assertTrue(self.ns['ack_inbox'](4))
        self.assertEqual(self.db.execute('SELECT count(*) FROM ne_inbox_quarantine').fetchone()[0], 3)
        self.assertEqual(self.drain(), [])

    def test_single_event_expanding_past_wire_budget_is_quarantined(self):
        self.add(json.dumps(dict(kind='inbound', t=0, content='😀' * 30000), ensure_ascii=False))
        batch = self.drain()
        self.assertEqual(batch[0]['kind'], 'inbox_error')
        self.assertLessEqual(len(json.dumps(batch).encode()), 256 * 1024)
        self.assertEqual(self.db.execute('SELECT count(*) FROM ne_inbox_quarantine').fetchone()[0], 1)

    def test_nonfinite_json_cannot_poison_the_swift_decoder(self):
        self.add('{"kind":"state","t":NaN}')
        self.assertEqual(self.drain()[0]['kind'], 'inbox_error')

    def test_ack_failure_is_reported_and_rows_remain_replayable(self):
        self.add(json.dumps(dict(kind='state', t=0)))
        self.db.execute("CREATE TRIGGER refuse_delete BEFORE DELETE ON ne_inbox BEGIN SELECT RAISE(ABORT,'test'); END")
        self.assertIs(self.ns['ack_inbox'](1), False)
        self.assertEqual(self.drain()[0]['seq'], 1)

    def test_ack_leaves_newer_rows_and_is_idempotent(self):
        self.add(json.dumps(dict(kind='state', t=0)))
        self.add(json.dumps(dict(kind='state', t=1)))
        self.assertTrue(self.ns['ack_inbox'](1))
        self.assertTrue(self.ns['ack_inbox'](1))
        self.assertEqual(self.drain()[0]['seq'], 2)


class _CountingConnection:
    """sqlite3.Connection proxy counting commits — i.e. the write amplification."""

    def __init__(self, conn):
        self._conn = conn
        self.commits = 0

    def commit(self):
        self.commits += 1
        self._conn.commit()

    def execute(self, sql, params=()):
        return self._conn.execute(sql, params)

    def executemany(self, sql, seq):
        return self._conn.executemany(sql, seq)


class AnnounceWritePathTests(unittest.TestCase):
    """The announce path is what blew iOS' disk-writes budget in the NE.

    One row + one WAL commit per received announce wrote 12.5 kB per announce
    (measured against these functions at 0.6 announce/s), and an app that stays
    suspended let the rows pile up into a b-tree every checkpoint had to rewrite.
    So announces must be buffered, coalesced, bounded, and flushed in one
    transaction — while every other event keeps the immediate path.
    """

    WANTED_FUNCS = {
        '_put', '_queue_announce', '_flush_announces', '_append_announces',
        '_ensure_announce_flusher', '_announce_flusher_loop',
    }

    def setUp(self):
        self.source = (Path(__file__).resolve().parents[2] / 'app/rns_bridge.py').read_text()
        tree = ast.parse(self.source)
        nodes = [n for n in tree.body if (
            isinstance(n, ast.FunctionDef) and n.name in self.WANTED_FUNCS
        ) or (
            isinstance(n, (ast.Assign, ast.AnnAssign))
            and any(isinstance(t, ast.Name) and (
                t.id.startswith('_ANNOUNCE_') or t.id.startswith('_announce_')
                or t.id == '_INBOX_ROWS_MAX'
            ) for t in (n.targets if isinstance(n, ast.Assign) else [n.target]))
        )]
        found = set()
        for node in nodes:
            if isinstance(node, ast.FunctionDef):
                found.add(node.name)
            else:
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                found.update(t.id for t in targets if isinstance(t, ast.Name))
        missing = self.WANTED_FUNCS - found
        self.assertFalse(missing, f'app/rns_bridge.py no longer defines {sorted(missing)}')

        self.db = sqlite3.connect(':memory:')
        self.db.execute('CREATE TABLE ne_inbox(seq INTEGER PRIMARY KEY, kind TEXT, '
                        'payload TEXT, created_at REAL)')
        self.published, self.pings = [], []
        self.ns = dict(
            json=json, time=time, threading=threading, queue=__import__('queue'), Any=Any,
            _inbox_path='<stub>', _inbox_conn=None, _inbox_bound_path=None,
            _inbox_lock=threading.RLock(), _durable_mode=True,
            _events=__import__('queue').Queue(),
            _open_inbox=lambda: None,
            _publish_durable=lambda kind, payload: self.published.append((kind, dict(payload))),
            _coalesced_events_ping=lambda: self.pings.append(1),
            RNS=SimpleNamespace(log=lambda *args: None, LOG_ERROR=1, LOG_WARNING=2),
        )
        exec(compile(ast.Module(body=nodes, type_ignores=[]), 'rns_bridge.py', 'exec'), self.ns)
        self.conn = _CountingConnection(self.db)
        self.ns['_inbox_conn'] = self.conn
        self.addCleanup(self.db.close)

    def announce(self, i, dest=None):
        return dict(dest_hash=dest or f'{i:032x}', app_data=f'peer-{i}',
                    aspect='lxmf.delivery', t=float(1000 + i))

    def rows(self, kind=None):
        sql = 'SELECT kind, payload FROM ne_inbox'
        if kind is None:
            return self.db.execute(sql).fetchall()
        return self.db.execute(sql + ' WHERE kind=?', (kind,)).fetchall()

    def keep_buffering(self):
        """A flush window longer than the test: nothing is due by time."""
        self.ns['_ANNOUNCE_FLUSH_INTERVAL'] = 600.0
        self.ns['_ANNOUNCE_FLUSH_MAX'] = 10_000
        self.ns['_announce_last_flush'] = float('inf')

    def test_announces_are_buffered_not_committed_per_event(self):
        self.keep_buffering()
        for i in range(25):
            self.ns['_put']('announce', **self.announce(i))
        self.assertEqual(self.rows(), [], 'announces must not hit the inbox per event')
        self.assertEqual(self.conn.commits, 0)
        self.assertEqual(self.published, [], 'announces are not published one by one')

        self.ns['_flush_announces']()
        self.assertEqual(len(self.rows('announce')), 25)
        self.assertEqual(self.conn.commits, 1, 'one transaction per flush window')
        self.assertEqual(len(self.pings), 1, 'one drain ping per flushed batch')

    def test_same_destination_is_coalesced_to_its_newest_announce(self):
        self.keep_buffering()
        for i in range(5):
            self.ns['_put']('announce', dest='ff' * 16, app_data=f'v{i}', t=float(i))
        self.ns['_flush_announces']()
        rows = self.rows('announce')
        self.assertEqual(len(rows), 1, 'one row per destination per window')
        self.assertEqual(json.loads(rows[0][1])['app_data'], 'v4', 'newest wins')

    def test_retained_announce_rows_are_bounded(self):
        self.ns['_ANNOUNCE_ROWS_MAX'] = 20
        self.ns['_ANNOUNCE_FLUSH_INTERVAL'] = 0.0
        for i in range(200):
            self.ns['_put']('announce', **self.announce(i))
            self.ns['_announce_last_flush'] = 0.0
        self.assertLessEqual(len(self.rows('announce')), 20,
                             'a suspended app must not grow announce rows without bound')

    def test_announce_cap_leaves_unread_events_of_other_kinds_alone(self):
        # The announce cutoff used to filter only the subquery, so the outer
        # DELETE removed EVERY row below it: at hub rates 1024 announces is ~18
        # minutes, and a delivery update that arrived while the app was suspended
        # could be deleted before the app ever drained it.
        self.ns['_ANNOUNCE_ROWS_MAX'] = 20
        self.ns['_INBOX_ROWS_MAX'] = 8192
        self.ns['_ANNOUNCE_FLUSH_INTERVAL'] = 0.0
        self.db.execute("INSERT INTO ne_inbox (kind, payload, created_at) "
                        "VALUES ('delivery', '{\"kind\":\"delivery\"}', 1.0)")
        unread = self.db.execute('SELECT seq FROM ne_inbox').fetchone()[0]
        for i in range(200):
            self.ns['_put']('announce', **self.announce(i))
            self.ns['_announce_last_flush'] = 0.0
        self.assertLessEqual(len(self.rows('announce')), 20)
        self.assertEqual(
            self.db.execute('SELECT kind FROM ne_inbox WHERE seq=?', (unread,)).fetchone(),
            ('delivery',), 'announce retention must not evict other kinds')

    def test_total_row_backstop_bounds_every_kind(self):
        # Exempting the other kinds must not make the store unbounded again: they
        # are drained by the app, but a long suspension still has to be capped.
        self.ns['_ANNOUNCE_ROWS_MAX'] = 10_000   # so the backstop is what binds
        self.ns['_INBOX_ROWS_MAX'] = 30
        self.ns['_ANNOUNCE_FLUSH_INTERVAL'] = 0.0
        for i in range(200):
            self.ns['_put']('announce', **self.announce(i))
            self.ns['_announce_last_flush'] = 0.0
        self.assertLessEqual(len(self.rows()), 30,
                             'the all-kind backstop must bound the table')

    def test_non_announce_events_keep_the_immediate_durable_path(self):
        self.keep_buffering()
        self.ns['_put']('state', value='connected')
        self.ns['_put']('link_state', destination_hash='ab' * 16, state='established')
        self.assertEqual([kind for kind, _ in self.published], ['state', 'link_state'])
        self.assertEqual(self.ns['_announce_buf'], {}, 'only announces are buffered')

    def test_inbound_events_are_not_enqueued_in_durable_mode(self):
        self.ns['_put']('inbound', message_hash='cd' * 16)
        self.assertEqual(self.published, [])
        self.assertEqual(self.ns['_announce_buf'], {})

    def test_arming_the_trailing_flush_does_not_deadlock(self):
        # `_ensure_announce_flusher` takes the buffer lock, so arming it while
        # `_queue_announce` still held that lock wedged the RNS announce-handler
        # thread and stalled every announce. Drive the REAL arming from a worker
        # thread: a regression deadlocks this test instead of the NE.
        self.keep_buffering()
        done = threading.Event()

        def worker():
            self.ns['_put']('announce', **self.announce(1))
            done.set()

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        thread.join(timeout=5.0)
        self.assertTrue(done.is_set(), 'buffering an announce must not block')
        self.assertEqual(self.rows(), [], 'arming alone must not commit')

    def test_stop_flushes_the_pending_batch_before_teardown(self):
        stop_body = self.source.split('def stop() -> None:', 1)[1].split('\n    with _lock:', 1)[0]
        self.assertIn('_flush_announces()', stop_body,
                      'a clean stop must persist the newest announce batch')


if __name__ == '__main__':
    unittest.main()
