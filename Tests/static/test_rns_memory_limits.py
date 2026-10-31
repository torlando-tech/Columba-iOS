"""Exercise the RNS memory caps and the `[MEM]` table census without loading RNS.

The functions are extracted from `app/rns_bridge.py` by AST and run against a
stub `RNS.Transport`, so the assertions cover the real code paths that run in
the Network Extension. Run:

    python3 -m unittest Tests.static.test_rns_memory_limits
"""
import ast
import importlib
import os
import tempfile
import types
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / 'app/rns_bridge.py'
FUNCTIONS = {
    '_apply_memory_limits',
    '_start_census_thread',
    '_table_census',
    '_census_line',
    '_ne_diag_path',
    '_diag_append',
}
ASSIGNMENTS = {'_MEMORY_LIMITS', '_DIAG_PATH', '_MEMORY_LIMITS_DISABLED_ENV',
               '_CENSUS_EVERY_SECONDS', '_CENSUS_STARTED'}


class FakeTransport16:
    """RNS >= 1.6.0 shape: PATH_TIMEOUT + the unused-pool target."""

    # Deliberately the RNS defaults, so the test proves the override wins.
    PATH_POOL_UNUSED_TARGET = 2048
    PATH_TIMEOUT = 60 * 60 * 24 * 7
    MAX_RANDOM_BLOBS = 64
    PERSIST_RANDOM_BLOBS = 32
    hashlist_maxsize = 1_000_000


class FakeTransport14:
    """RNS <= 1.5.x shape (what the device payload actually ships): the path
    timeout is DESTINATION_TIMEOUT and there is no pool target."""

    DESTINATION_TIMEOUT = 60 * 60 * 24 * 7
    MAX_RANDOM_BLOBS = 64
    PERSIST_RANDOM_BLOBS = 32
    hashlist_maxsize = 1_000_000


def build_namespace(transport_cls=FakeTransport16):
    tree = ast.parse(SOURCE.read_text())
    nodes = [
        n for n in tree.body
        if (isinstance(n, ast.FunctionDef) and n.name in FUNCTIONS)
        or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ASSIGNMENTS for t in n.targets))
        or (isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name) and n.target.id in ASSIGNMENTS)
    ]
    # Fresh subclass per namespace: the caps test mutates class attributes and
    # must not leak into the tests that assert the untouched RNS defaults.
    transport = type('FakeTransport', (), dict(vars(transport_cls)))
    identity = type('FakeIdentity', (), {})
    ns = {
        'RNS': SimpleNamespace(Transport=transport, Identity=identity, __version__='9.9.9'),
        'os': os,
        'time': time,
        'threading': types.SimpleNamespace(
            Thread=lambda *a, **k: types.SimpleNamespace(start=lambda: None, daemon=True)),
        'queue': None,
        '_state': {},
        '_DIAG_PATH': [],
    }
    exec(compile(ast.Module(body=nodes, type_ignores=[]), 'rns_bridge.py', 'exec'), ns)
    return ns


class MemoryLimitTests(unittest.TestCase):
    def setUp(self):
        self.ns = build_namespace()
        self.addCleanup(mock.patch.dict(os.environ, {}, clear=False).stop)
        os.environ.pop('COLUMBA_RNS_UNCAPPED', None)

    def test_caps_override_the_rns_defaults(self):
        applied = self.ns['_apply_memory_limits']()
        self.assertEqual(applied['PATH_TIMEOUT'], 3600)
        self.assertEqual(applied['PATH_POOL_UNUSED_TARGET'], 512)
        self.assertEqual(applied['MAX_RANDOM_BLOBS'], 16)
        transport = self.ns['RNS'].Transport
        self.assertEqual(transport.PATH_TIMEOUT, 3600)
        self.assertEqual(transport.PATH_POOL_UNUSED_TARGET, 512)
        self.assertEqual(transport.MAX_RANDOM_BLOBS, 16)
        self.assertEqual(transport.PERSIST_RANDOM_BLOBS, 16)
        # Both layouts read hashlist_maxsize at swap time, so the same cap
        # bounds the 1.6.0 dense list and the 1.4.2 `set` alike.
        self.assertEqual(applied['hashlist_maxsize'], 100_000)
        self.assertEqual(transport.hashlist_maxsize, 100_000)

    def test_only_attributes_the_running_rns_defines_are_written(self):
        # The device payload ships RNS 1.4.2: no PATH_TIMEOUT, no pool target.
        # Writing those names would be inert yet reported as applied.
        self.ns = build_namespace(FakeTransport14)
        applied = self.ns['_apply_memory_limits']()
        self.assertEqual(applied['DESTINATION_TIMEOUT'], 3600)
        self.assertEqual(self.ns['RNS'].Transport.DESTINATION_TIMEOUT, 3600)
        self.assertEqual(self.ns['RNS'].Transport.MAX_RANDOM_BLOBS, 16)
        self.assertEqual(applied['hashlist_maxsize'], 100_000)
        self.assertNotIn('PATH_TIMEOUT', applied)
        self.assertNotIn('PATH_POOL_UNUSED_TARGET', applied)
        self.assertFalse(hasattr(self.ns['RNS'].Transport, 'PATH_TIMEOUT'))

    def test_persisted_blobs_never_exceed_in_memory_blobs(self):
        # Transport.py:4109 reloads PERSIST_RANDOM_BLOBS into memory on restart,
        # so a larger persist cap would resurrect more blobs than the memory cap.
        limits = dict(self.ns['_MEMORY_LIMITS'])
        self.assertLessEqual(limits['PERSIST_RANDOM_BLOBS'], limits['MAX_RANDOM_BLOBS'])
        # Both path-timeout spellings are covered, whichever the payload has.
        self.assertIn('DESTINATION_TIMEOUT', limits)
        self.assertIn('PATH_TIMEOUT', limits)

    def test_env_switch_disables_caps(self):
        os.environ['COLUMBA_RNS_UNCAPPED'] = '1'
        self.assertEqual(self.ns['_apply_memory_limits'](), {})
        transport = self.ns['RNS'].Transport
        self.assertEqual(transport.PATH_TIMEOUT, 60 * 60 * 24 * 7)
        self.assertEqual(transport.PATH_POOL_UNUSED_TARGET, 2048)
        self.assertEqual(transport.hashlist_maxsize, 1_000_000)

    @unittest.skipUnless(importlib.util.find_spec('RNS'), 'RNS not installed')
    def test_every_limit_names_a_real_transport_attribute(self):
        """A cap RNS does not read is inert, so every name must be real.

        The two path-timeout spellings belong to different layouts, so at most one
        can exist on a given version - require that one of them does, and require
        every other name unconditionally.
        """
        import RNS
        timeout_names = {'DESTINATION_TIMEOUT', 'PATH_TIMEOUT'}
        limits = self.ns['_MEMORY_LIMITS']
        for name, value in limits:
            if name in timeout_names:
                continue
            with self.subTest(name=name):
                self.assertTrue(hasattr(RNS.Transport, name),
                                f'RNS.Transport.{name} does not exist')
                self.assertIsInstance(value, int)
        live = [n for n, _ in limits
                if n in timeout_names and hasattr(RNS.Transport, n)]
        self.assertTrue(live, 'no path-timeout attribute on this RNS')


class CensusTests(unittest.TestCase):
    def setUp(self):
        self.ns = build_namespace()
        self.transport = self.ns['RNS'].Transport
        self.transport.path_table = {
            b'a' * 16: [0, None, 0, 9e9, [b'blob1'], None, b'h', 0],       # unused
            b'b' * 16: [0, None, 0, 9e9, [b'blob1', b'blob2'], None, b'h', 1234.5],  # used
            # RNS <= 1.5.x entries have no IDX_PT_USED slot at all.
            b'c' * 16: [0, None, 0, 9e9, [b'blob1'], None, b'h'],  # 7 fields
        }
        self.ns['RNS'].Identity.known_destinations = {
            b'a' * 16: [0, b'ph', b'pk', b'app', 0, None, 0],
            b'b' * 16: [0, b'ph', b'pk', b'app', 1234.5, None, 0],
        }
        self.transport.path_states = {b'a' * 16: 2}
        self.transport.announce_rate_table = {b'a' * 16: object()}
        self.transport.packet_hashlist = [1, 2, 3]
        self.transport.held_announces = {}
        self.transport.reverse_table = {1: 2}
        self.transport.link_table = {}
        self.transport.tunnels = {}
        self.transport.path_requests = {b'x': 1}
        self.transport.announce_table = {b'y': 1}
        self.transport.interfaces = [object(), object()]

    def test_census_counts_entries_and_the_used_split(self):
        counts = self.ns['_table_census']()
        self.assertEqual(counts['pt'], 3)
        self.assertEqual(counts['ptu'], 2, 'unused = IDX_PT_USED == 0 or no used slot at all')
        self.assertEqual(counts['kd'], 2)
        self.assertEqual(counts['blobs'], 4, 'blob lists come from path_table, not Identity')
        self.assertEqual(counts['art'], 1)
        self.assertEqual(counts['phl'], 3)
        self.assertEqual(counts['ifs'], 2)
        line = self.ns['_census_line'](counts)
        self.assertTrue(line.startswith('[MEM] '))
        self.assertIn('ptu=2', line)

    def test_census_survives_a_partially_initialised_transport(self):
        self.transport.path_table = None
        del self.ns['RNS'].Identity.known_destinations
        counts = self.ns['_table_census']()
        self.assertNotIn('pt', counts)
        self.assertNotIn('kd', counts)
        self.assertEqual(counts['ps'], 1)

    def test_census_without_any_transport_is_empty_not_an_error(self):
        self.ns['RNS'] = SimpleNamespace(Transport=None, Identity=None)
        self.assertEqual(self.ns['_table_census'](), {})


class LimitsLineTests(unittest.TestCase):
    """The one-shot `[MEM] limits` line must name the running RNS and every cap
    that is inert on it, so a capped-looking log cannot hide an inert knob."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        cfg = Path(self.tmp.name) / 'cfg'
        cfg.mkdir()
        self.cfg = cfg

    def _line(self, ns, applied):
        ns['_state']['config_dir'] = str(self.cfg)
        ns['_start_census_thread'](applied)
        text = (self.cfg / 'mem-diag.log').read_text()
        return text.splitlines()[0]

    def test_line_names_version_and_applied_caps(self):
        ns = build_namespace()
        line = self._line(ns, {'PATH_TIMEOUT': 3600, 'MAX_RANDOM_BLOBS': 16})
        self.assertIn('rns=9.9.9', line)
        self.assertIn('PATH_TIMEOUT=3600', line)
        self.assertIn('MAX_RANDOM_BLOBS=16', line)
        self.assertIn('inert=DESTINATION_TIMEOUT,PATH_POOL_UNUSED_TARGET,PERSIST_RANDOM_BLOBS', line)

    def test_line_reports_uncapped_run_explicitly(self):
        ns = build_namespace()
        os.environ['COLUMBA_RNS_UNCAPPED'] = '1'
        self.addCleanup(os.environ.pop, 'COLUMBA_RNS_UNCAPPED', None)
        line = self._line(ns, ns['_apply_memory_limits']())
        self.assertIn('uncapped', line)
        self.assertIn('COLUMBA_RNS_UNCAPPED', line)


class DiagChannelTests(unittest.TestCase):
    def setUp(self):
        self.ns = build_namespace()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _dirs(self):
        root = Path(self.tmp.name) / 'group'
        cfg = root / 'Columba' / 'python-abc'
        cfg.mkdir(parents=True)
        return root, cfg

    def test_writes_into_the_app_group_extension_log_the_app_mirrors(self):
        root, cfg = self._dirs()
        (root / 'Library').mkdir()
        self.ns['_state']['config_dir'] = str(cfg)
        self.assertTrue(self.ns['_diag_append']('[MEM] pt=1'))
        self.assertTrue(self.ns['_diag_append']('[MEM] pt=2'))
        text = (root / 'Library' / 'ext-diag.log').read_text()
        self.assertIn('[MEM] pt=1', text)
        self.assertIn('[MEM] pt=2', text)
        self.assertEqual(len(text.splitlines()), 2)
        self.assertFalse((cfg / 'mem-diag.log').exists())

    def test_falls_back_to_a_config_sibling_when_library_is_absent(self):
        _root, cfg = self._dirs()
        self.ns['_state']['config_dir'] = str(cfg)
        self.assertTrue(self.ns['_diag_append']('[MEM] pt=3'))
        self.assertIn('[MEM] pt=3', (cfg / 'mem-diag.log').read_text())

    def test_no_config_dir_is_a_silent_noop(self):
        self.assertFalse(self.ns['_diag_append']('[MEM] pt=4'))


if __name__ == '__main__':
    unittest.main()
