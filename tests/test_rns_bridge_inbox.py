"""Exercise the real inbox functions with SQLite, without loading iOS/RNS.

Only the named functions/constants are extracted; their SQL and replay logic run
unchanged. Run: python3 -m unittest discover -s tests -p test_rns_bridge_inbox.py
"""
import ast
import json
import sqlite3
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace


class InboxReplayTests(unittest.TestCase):
    def setUp(self):
        source = ast.parse((Path(__file__).resolve().parents[1] / 'app/rns_bridge.py').read_text())
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


if __name__ == '__main__':
    unittest.main()
