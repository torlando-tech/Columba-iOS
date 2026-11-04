import ast
from array import array
from collections import deque
import ctypes
import os
from pathlib import Path
import queue
import re
import sys
import threading
import time
import types
import unittest
from typing import Any


BRIDGE = Path(__file__).resolve().parents[2] / "app" / "rns_bridge.py"
FUNCTIONS = {
    "_memory_children", "_bounded_graph_size", "_parse_pymalloc_stats",
    "_pymalloc_stats", "_memory_attribution_roots", "_memory_attribution_lines",
    "_start_census_thread",
}
CONSTANTS = {
    "_MEMORY_ATTRIBUTION_ENV", "_MEMORY_ATTRIBUTION_SECONDS",
    "_MEMORY_GRAPH_NODES", "_MEMORY_GRAPH_REFS", "_MEMORY_GRAPH_DEPTH",
    "_MEMORY_GRAPH_SECONDS", "_MEMORY_SAMPLE_SECONDS", "_PYMALLOC_BUFFER_BYTES",
}
REPORT = b"""Small block threshold = 512, in 32 size classes.
# arenas allocated current         =                    2
2 arenas * 1048576 bytes/arena      =            2,097,152
# bytes in allocated blocks        =            1,000,000
# bytes in available blocks        =              100,000
3 unused pools * 16384 bytes       =               49,152
"""


def load_functions():
    tree = ast.parse(BRIDGE.read_text(encoding="utf-8"))
    nodes = [node for node in tree.body if (
        isinstance(node, ast.FunctionDef) and node.name in FUNCTIONS
    ) or (
        isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id in CONSTANTS
                for target in node.targets)
    )]
    namespace = dict(Any=Any, array=array, deque=deque, ctypes=ctypes, re=re, sys=sys,
                     time=time, threading=threading, os=os,
                     _lock=threading.Lock(), _state={"router": None},
                     _events=queue.Queue(),
                     RNS=types.SimpleNamespace(Transport=types.SimpleNamespace(),
                                               Identity=types.SimpleNamespace()))
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(BRIDGE), "exec"), namespace)
    return namespace


class GraphSizeTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_functions()

    def size(self, root, **limits):
        return self.ns["_bounded_graph_size"](root, seconds=1.0, **limits)

    def test_literal_dictionary_counts_keys_values_and_payload(self):
        key, number, payload = "literal-key", 1234567, b"literal-payload"
        child = [number, payload]
        root = {key: child}
        result = self.size(root)
        expected = sum(sys.getsizeof(obj) for obj in (root, key, child, number, payload))
        self.assertEqual(result["reachable_bytes"], expected)
        self.assertEqual(result["root_bytes"], sys.getsizeof(root))
        self.assertEqual(result["root_len"], 1)
        self.assertEqual(result["visited"], 5)
        self.assertEqual(result["status"], "complete")

    def test_all_supported_containers_and_leaf_types(self):
        for root in ([1001], (1001,), {1001}, frozenset({1001}), deque([1001])):
            with self.subTest(kind=type(root)):
                self.assertEqual(self.size(root)["reachable_bytes"],
                                 sys.getsizeof(root) + sys.getsizeof(1001))
        for root in (b"payload", "unicode \u2603", bytearray(b"mutable"),
                     1001, True, 1.25, 1j, None):
            with self.subTest(kind=type(root)):
                self.assertEqual(self.size(root)["reachable_bytes"], sys.getsizeof(root))

    def test_shared_references_and_cycle_deduplicate_per_root(self):
        payload = b"shared-payload"
        child = [payload]
        root = [child, child]
        root.append(root)
        result = self.size(root)
        self.assertEqual(result["reachable_bytes"],
                         sum(sys.getsizeof(obj) for obj in (root, child, payload)))
        self.assertEqual(result["visited"], 3)
        self.assertEqual(result["duplicates"], 2)
        self.assertEqual(result["status"], "complete")
        self.assertEqual(self.size(root)["reachable_bytes"], result["reachable_bytes"])

    def test_shared_dictionary_key_and_value_count_once(self):
        payload = b"both-key-and-value"
        root = {payload: payload}
        self.assertEqual(self.size(root)["reachable_bytes"],
                         sys.getsizeof(root) + sys.getsizeof(payload))

    def test_bytes_growth_visible_without_container_count_growth(self):
        small, large = b"x" * 16, b"x" * 4096
        first, second = self.size([small]), self.size([large])
        self.assertEqual(first["visited"], second["visited"])
        self.assertEqual(second["reachable_bytes"] - first["reachable_bytes"],
                         sys.getsizeof(large) - sys.getsizeof(small))

    def test_numeric_array_counts_inline_storage_without_boxing_elements(self):
        root = array("d", range(10000))
        result = self.size(root)
        self.assertEqual(result["reachable_bytes"], sys.getsizeof(root))
        self.assertEqual(result["root_len"], 10000)
        self.assertEqual(result["visited"], 1)
        self.assertEqual(result["status"], "complete")

    def test_views_deduplicate_backing_buffer(self):
        backing = bytearray(b"buffer")
        one, two = memoryview(backing), memoryview(backing)[1:]
        root = [one, two, backing]
        result = self.size(root)
        self.assertEqual(result["reachable_bytes"],
                         sum(sys.getsizeof(obj) for obj in (root, one, two, backing)))
        self.assertEqual(result["status"], "complete")

    def test_released_view_is_partial(self):
        view = memoryview(b"released")
        view.release()
        result = self.size(view)
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["mutated"], 1)
        self.assertEqual(result["root_len"], -1)

    def test_node_reference_and_depth_caps(self):
        for limit, value, flag, counter in (
            ("max_nodes", 3, "capped_nodes", "visited"),
            ("max_refs", 2, "capped_refs", "examined"),
        ):
            with self.subTest(limit=limit):
                result = self.size(list(range(100)), **{limit: value})
                self.assertEqual(result[flag], 1)
                self.assertLessEqual(result[counter], value)
                self.assertEqual(result["root_len"], 100)
                self.assertEqual(result["status"], "partial")
        result = self.size([[[b"unreached"]]], max_depth=1)
        self.assertEqual(result["capped_depth"], 1)
        self.assertEqual(result["visited"], 2)
        self.assertEqual(result["status"], "partial")

    def test_expired_deadline_does_not_visit_graph(self):
        self.ns["time"] = types.SimpleNamespace(monotonic=lambda: 10.0)
        result = self.size([b"unvisited"], deadline=9.0)
        self.assertEqual(result["visited"], 0)
        self.assertEqual(result["deadline"], 1)
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["root_len"], 1)

    def test_unknown_instances_and_subclasses_are_opaque_without_hooks(self):
        class Private:
            def __sizeof__(self):
                raise AssertionError("user sizeof invoked")

            def __iter__(self):
                raise AssertionError("user iteration invoked")

            def __repr__(self):
                raise AssertionError("private repr invoked")

            @property
            def __dict__(self):
                raise AssertionError("private dict inspected")

        class PrivateList(list):
            def __len__(self):
                raise AssertionError("user length invoked")

        for obj in (Private(), PrivateList(), sys, lambda: None):
            result = self.size(obj)
            self.assertEqual(result["opaque"], 1)
            self.assertEqual(result["root_bytes"], -1)
            self.assertEqual(result["root_len"], -1)
            self.assertEqual(result["reachable_bytes"], 0)
            self.assertEqual(result["status"], "opaque")

    def test_mutation_errors_are_partial_and_do_not_escape(self):
        def mutating_children(_root):
            yield 1
            raise RuntimeError("PRIVATE_KEY")

        self.ns["_memory_children"] = mutating_children
        result = self.size([1])
        self.assertEqual(result["mutated"], 1)
        self.assertEqual(result["status"], "partial")
        self.assertNotIn("PRIVATE_KEY", str(result))



class AllocatorStatsTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_functions()

    def test_known_numeric_report(self):
        result = self.ns["_parse_pymalloc_stats"](REPORT)
        self.assertEqual(result, dict(status="complete", arenas_current=2,
                                     arena_bytes=2097152, arena_size=1048576,
                                     allocated_block_bytes=1000000,
                                     available_block_bytes=100000,
                                     unused_pools=3, unused_pool_bytes=49152,
                                     pool_size=16384))

    def test_unsupported_inconsistent_and_malformed_reports(self):
        for raw in (
            b"mimalloc PRIVATE_PATH", b"", None, b"\xff",
            REPORT.replace(b"1,000,000", b"1,,000,000"),
            REPORT.replace(b"2,097,152", b"2,097,153"),
            REPORT.replace(b"49,152", b"49,153"),
            REPORT.replace(b"# arenas allocated current", b"# unknown label"),
            REPORT + b"# arenas allocated current = 2\n",
            REPORT.replace(b"1,000,000", b"9,000,000"),
        ):
            with self.subTest(raw=raw):
                self.assertEqual(self.ns["_parse_pymalloc_stats"](raw),
                                 {"status": "unavailable"})

    def test_truncated_report_returns_no_partial_numbers_or_text(self):
        parse = self.ns["_parse_pymalloc_stats"]
        self.assertEqual(parse(REPORT, truncated=True), {"status": "truncated"})
        self.assertEqual(parse(b"P" * 8192), {"status": "truncated"})

    def test_unverified_runtime_never_calls_private_api(self):
        self.ns["sys"] = types.SimpleNamespace(
            implementation=types.SimpleNamespace(name="cpython"), version_info=(3, 12))
        self.ns["ctypes"] = object()
        self.assertEqual(self.ns["_pymalloc_stats"](), {"status": "unavailable"})

    def fake_capture(self, report=REPORT, flushed=0, length=None, supported=1):
        class Function:
            def __init__(self, fn):
                self.fn = fn

            def __call__(self, *args):
                return self.fn(*args)

        state = {"closed": False}

        def opened(buffer, size, mode):
            self.assertEqual(size, 8192)
            self.assertEqual(mode, b"w")
            state["buffer"] = buffer
            return 123

        def capture(stream):
            self.assertEqual(stream, 123)
            ctypes.memmove(state["buffer"], report, min(len(report), 8191))
            return supported

        def closed(stream):
            self.assertEqual(stream, 123)
            state["closed"] = True
            return 0

        private = Function(capture)
        libc = types.SimpleNamespace(
            fmemopen=Function(opened), fflush=Function(lambda _: flushed),
            ftell=Function(lambda _: len(report) if length is None else length),
            fclose=Function(closed))
        self.ns["sys"] = types.SimpleNamespace(
            implementation=types.SimpleNamespace(name="cpython"), version_info=(3, 13))
        self.ns["ctypes"] = types.SimpleNamespace(
            pythonapi=types.SimpleNamespace(_PyObject_DebugMallocStats=private),
            CDLL=lambda _: libc, create_string_buffer=ctypes.create_string_buffer,
            c_void_p=ctypes.c_void_p, c_size_t=ctypes.c_size_t,
            c_char_p=ctypes.c_char_p, c_int=ctypes.c_int, c_long=ctypes.c_long)
        return state, private

    def test_capture_closes_memory_stream_after_valid_report(self):
        state, _ = self.fake_capture()
        self.assertEqual(self.ns["_pymalloc_stats"]()["status"], "complete")
        self.assertTrue(state["closed"])

    def test_capture_overflow_and_unsupported_allocator_close_stream(self):
        for options, status in ((dict(flushed=-1), "truncated"),
                                (dict(length=8191), "truncated"),
                                (dict(supported=0), "unavailable")):
            with self.subTest(options=options):
                state, _ = self.fake_capture(**options)
                self.assertEqual(self.ns["_pymalloc_stats"](), {"status": status})
                self.assertTrue(state["closed"])

    def test_missing_symbol_is_unavailable(self):
        self.ns["sys"] = types.SimpleNamespace(
            implementation=types.SimpleNamespace(name="cpython"), version_info=(3, 13))
        self.ns["ctypes"] = types.SimpleNamespace(pythonapi=object())
        self.assertEqual(self.ns["_pymalloc_stats"](), {"status": "unavailable"})


class AttributionIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.ns = load_functions()
        self.ns["os"] = types.SimpleNamespace(getpid=lambda: 123,
                                               environ={"COLUMBA_MEMORY_ATTRIBUTION": "1"})


    def test_dense_hash_generations_and_rate_buffers_are_measured(self):
        current, previous = [bytearray(128)], [bytearray(256)]
        index, keys, times = {b"peer": 0}, [b"peer"], array("d", [1.0, 2.0])
        self.ns["RNS"].Transport.packet_hashlist = types.SimpleNamespace(
            _cur=current, _prv=previous)
        self.ns["RNS"].Transport.announce_rate_table = types.SimpleNamespace(
            _index=index, _keys=keys, _ts=times)
        self.ns["_pymalloc_stats"] = lambda: {"status": "unavailable"}
        lines = self.ns["_memory_attribution_lines"]()
        def metrics(category):
            line = next(line for line in lines if f"category={category} " in line)
            return dict(field.split("=", 1) for field in line.split() if "=" in field)
        self.assertEqual(int(metrics("rns_hash_current")["reachable_bytes"]),
                         sys.getsizeof(current) + sys.getsizeof(current[0]))
        self.assertEqual(int(metrics("rns_hash_previous")["reachable_bytes"]),
                         sys.getsizeof(previous) + sys.getsizeof(previous[0]))
        self.assertEqual(int(metrics("rns_rate_timestamps")["reachable_bytes"]),
                         sys.getsizeof(times))
        self.assertEqual(metrics("rns_rate_timestamps")["status"], "complete")

    def test_absent_table_roots_emit_unavailable_not_none_size(self):
        self.ns["_pymalloc_stats"] = lambda: {"status": "unavailable"}
        lines = self.ns["_memory_attribution_lines"]()
        missing = [line for line in lines if "category=rns_" in line or "category=lxmf_" in line]
        self.assertTrue(missing)
        for line in missing:
            self.assertTrue(line.endswith("status=unavailable"))
            self.assertNotIn("reachable_bytes=", line)
        # None remains a supported real leaf inside a present graph.
        self.assertEqual(self.ns["_bounded_graph_size"](None)["reachable_bytes"],
                         sys.getsizeof(None))


    def test_output_never_emits_private_payloads_or_object_addresses(self):
        private = {"PRIVATE_KEY_PATH": [b"PRIVATE_PAYLOAD", object()]}
        self.ns["_memory_attribution_roots"] = lambda: [("rns_path_table", private)]
        self.ns["_pymalloc_stats"] = lambda: {"status": "unavailable"}
        lines = self.ns["_memory_attribution_lines"]()
        joined = "\n".join(lines)
        self.assertNotIn("PRIVATE", joined)
        self.assertNotIn("0x", joined)
        self.assertRegex(joined, r"wall_ms=[0-9]+ pid=123")
        self.assertRegex(lines[0], r"allocated_blocks=[0-9]+ elapsed_ms=[0-9]+")
        first = dict(field.split("=", 1) for field in lines[1].split()[1:])
        self.assertEqual(first["status"], "opaque")
        for field, value in first.items():
            if field not in ("category", "status"):
                self.assertRegex(value, r"^-?[0-9]+$")

    def test_traversal_and_allocator_capture_do_not_hold_bridge_lock(self):
        lock = self.ns["_lock"]
        self.ns["RNS"].Transport.path_table = {}
        size = self.ns["_bounded_graph_size"]

        def checked_size(root, **options):
            self.assertFalse(lock.locked())
            return size(root, **options)

        def checked_allocator():
            self.assertFalse(lock.locked())
            return {"status": "unavailable"}

        self.ns["_bounded_graph_size"] = checked_size
        self.ns["_pymalloc_stats"] = checked_allocator
        self.ns["_memory_attribution_lines"]()

    def test_census_worker_gates_first_sample_and_300_second_cadence(self):
        class StopLoop(BaseException):
            pass

        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                clock, samples, emitted = [0.0], [], []
                self.ns["os"].environ = {"COLUMBA_MEMORY_ATTRIBUTION": "1" if enabled else "0"}
                self.ns.update(_CENSUS_STARTED=[False], _CENSUS_EVERY_SECONDS=60.0,
                               _MEMORY_LIMITS=(), _MEMORY_LIMITS_DISABLED_ENV="DISABLED")

                def sleep(seconds):
                    clock[0] += seconds
                    if clock[0] >= 360:
                        raise StopLoop()

                def sample():
                    self.assertFalse(self.ns["_lock"].locked())
                    samples.append(clock[0])
                    return ["[PYMEM] category=sample status=complete"]

                def output(line, **_options):
                    self.assertFalse(self.ns["_lock"].locked())
                    emitted.append(line)

                class Thread:
                    def __init__(self, *, target, **_options):
                        self.target = target

                    def start(self):
                        self.target()

                self.ns.update(time=types.SimpleNamespace(monotonic=lambda: clock[0], sleep=sleep),
                               threading=types.SimpleNamespace(Thread=Thread),
                               _memory_attribution_lines=sample,
                               _table_census=lambda: {"pt": 1},
                               _census_line=lambda _: "[MEM] pt=1",
                               _diag_append=output, print=output)
                with self.assertRaises(StopLoop):
                    self.ns["_start_census_thread"]({})
                self.assertEqual(samples, [0.0, 300.0] if enabled else [])
                self.assertTrue(any(line.startswith("[MEM]") for line in emitted))


if __name__ == "__main__":
    unittest.main()
