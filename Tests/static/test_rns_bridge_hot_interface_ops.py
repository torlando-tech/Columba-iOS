"""Static test for the RNS 1.5.5 hot interface attach/detach refactor.

`app/rns_bridge.py` cannot be imported whole (import-time side effects: sys
redirect, ctypes.CDLL, platform patch - see
references/rns-bridge-static-test-seam.md). We AST-extract only
`add_interface` / `remove_interface` and exec them in a seeded namespace whose
`RNS` is a controllable fake. This verifies the refactor's core contract:

- `add_interface` delegates to RNS 1.5.5's PUBLIC `Reticulum.attach_interface`
  (not the removed internal `_synthesize_interface` path) and maps its
  return (None / True / False) to honest {ok, reason} values.
- `remove_interface` delegates to `Reticulum.detach_interface` and is
  idempotent (detaching an absent interface returns ok=True / not-found, so a
  caller reconciling from a stale live-set does not treat it as a failure).
- The config pre-check (section-not-found) and the not-started guard hold.

The RNS 1.5.5 return semantics under test (from RNS/Reticulum.py
`_attach_interface` / `_detach_interface` on the pinned branch):
  attach:  False -> already-present or management disabled
           None  -> config entry missing / unparseable
           True  -> attached
  detach:  None  -> not present
           False -> I2P/Local or failed
           True  -> detached
"""
import ast
import re
import sys
import threading
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"

WANTED = {"add_interface", "remove_interface"}


def _extract_namespace():
    """AST-extract add_interface/remove_interface into a fresh, seeded ns."""
    tree = ast.parse(BRIDGE.read_text())
    fns = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in WANTED]
    assert len(fns) == len(WANTED), f"expected {WANTED}, got {[f.name for f in fns]}"

    ns = {
        "os": __import__("os"),
        "Any": __import__("typing").Any,
        "_lock": threading.RLock(),
        "_state": {
            "started": True,
            "reticulum": None,
            "config_dir": None,
        },
        "RNS": None,  # set per-test below
    }
    exec(compile(ast.Module(body=fns, type_ignores=[]), str(BRIDGE), "exec"), ns)
    return ns


# --- Fake RNS objects -------------------------------------------------------


class FakeIface:
    def __init__(self, name):
        self.name = name


class _Transport:
    def __init__(self):
        self.interfaces = []


class FakeReticulum:
    """Mimics RNS 1.5.5 `attach_interface` / `detach_interface` returns."""

    def __init__(self, transport, sections):
        self._transport = transport
        self._sections = set(sections)

    def attach_interface(self, name):
        if any(getattr(i, "name", None) == name for i in self._transport.interfaces):
            return False  # already present
        if name not in self._sections:
            return None  # no config entry
        self._transport.interfaces.append(FakeIface(name))
        return True

    def detach_interface(self, name):
        for i in list(self._transport.interfaces):
            if getattr(i, "name", None) == name:
                self._transport.interfaces.remove(i)
                return True
        return None  # not present


class _FakeRNS:
    LOG_DEBUG = 2
    LOG_NOTICE = 4
    LOG_WARNING = 3
    LOG_ERROR = 1

    def __init__(self, transport):
        self.Transport = transport
        self.panic = staticmethod(lambda *a, **k: (_ for _ in ()).throw(RuntimeError("panic")))
        self.trace_exception = lambda e: None
        self.log = lambda *a, **k: None


_ABSENT = object()


def _install_fake_configobj():
    """Provide RNS.vendor.configobj.ConfigObj for the function's inner import.

    Returns the prior ``sys.modules`` state for every key it touches so the
    caller can restore it (see :func:`_restore_fake_configobj`). The CI static
    harness runs many test modules in one interpreter, so leaving these fakes
    in ``sys.modules`` would shadow other tests' real imports (P2).
    """
    mod = types.ModuleType("RNS.vendor.configobj")

    class ConfigObj:
        def __init__(self, path):
            text = Path(path).read_text()
            sections = set(re.findall(r"\[\[\s*([\w.\-]+)\s*\]\]", text))
            self._d = {"interfaces": {s: {} for s in sections}}

        def __contains__(self, k):
            return k in self._d

        def __getitem__(self, k):
            return self._d[k]

    mod.ConfigObj = ConfigObj
    vendor = types.ModuleType("RNS.vendor")
    vendor.configobj = mod
    prior = {key: sys.modules.get(key, _ABSENT)
             for key in ("RNS", "RNS.vendor", "RNS.vendor.configobj")}
    sys.modules.setdefault("RNS", types.ModuleType("RNS"))
    sys.modules.setdefault("RNS.vendor", vendor)
    sys.modules["RNS.vendor.configobj"] = mod
    return prior


def _restore_fake_configobj(prior):
    """Undo :func:`_install_fake_configobj`: restore each ``sys.modules`` key to
    its prior value, or remove it if it was absent before the test ran."""
    for key, old in prior.items():
        if old is _ABSENT:
            sys.modules.pop(key, None)
        else:
            sys.modules[key] = old


class HotInterfaceOpsTest(unittest.TestCase):
    def setUp(self):
        self._mod_prior = _install_fake_configobj()
        self.ns = _extract_namespace()
        self.transport = _Transport()
        self.rns = _FakeRNS(self.transport)
        self.config_dir = _write_config(["relay1"])
        self.ns["_state"]["config_dir"] = str(self.config_dir)
        self.ret = FakeReticulum(self.transport, sections=["relay1"])
        self.ns["_state"]["reticulum"] = self.ret
        self.ns["RNS"] = self.rns

    def tearDown(self):
        # P2: restore sys.modules so these fakes don't shadow other tests'
        # imports in the CI static harness (one interpreter, many modules).
        _restore_fake_configobj(self._mod_prior)

    # --- add_interface ------------------------------------------------------

    def test_add_delegates_to_public_attach_and_reports_ok(self):
        res = self.ns["add_interface"]("relay1")
        self.assertEqual(res, {"ok": True, "reason": "attached"})
        self.assertTrue(any(getattr(i, "name", None) == "relay1" for i in self.transport.interfaces))
        # It used the new public API, not the old internal path.
        self.assertTrue(hasattr(self.ret, "attach_interface"))

    def test_add_already_present_is_ok(self):
        self.transport.interfaces.append(FakeIface("relay1"))
        res = self.ns["add_interface"]("relay1")
        self.assertEqual(res, {"ok": True, "reason": "already-present"})

    def test_add_section_not_found(self):
        res = self.ns["add_interface"]("missing")
        self.assertEqual(res, {"ok": False, "reason": "section-not-found: missing"})
        self.assertFalse(any(getattr(i, "name", None) == "missing" for i in self.transport.interfaces))

    def test_add_not_started(self):
        self.ns["_state"]["started"] = False
        res = self.ns["add_interface"]("relay1")
        self.assertEqual(res, {"ok": False, "reason": "not-started"})

    def test_add_panic_maps_to_failure(self):
        # A bad config / unreachable endpoint makes attach panic (os._exit in
        # real RNS); rns_bridge swaps panic for an exception and reports failure.
        self.ret.attach_interface = lambda name: (_ for _ in ()).throw(RuntimeError("boom"))
        res = self.ns["add_interface"]("relay1")
        self.assertEqual(res["ok"], False)

    # --- remove_interface ---------------------------------------------------

    def test_remove_delegates_to_public_detach_and_reports_ok(self):
        self.transport.interfaces.append(FakeIface("relay1"))
        res = self.ns["remove_interface"]("relay1")
        self.assertEqual(res, {"ok": True, "reason": "removed"})
        self.assertFalse(any(getattr(i, "name", None) == "relay1" for i in self.transport.interfaces))

    def test_remove_not_found_is_ok_idempotent(self):
        # Desired end state (absent) already holds -> ok, not a failure.
        res = self.ns["remove_interface"]("ghost")
        self.assertEqual(res, {"ok": True, "reason": "not-found"})

    def test_remove_not_started(self):
        self.ns["_state"]["started"] = False
        res = self.ns["remove_interface"]("relay1")
        self.assertEqual(res, {"ok": False, "reason": "not-started"})

    def test_detach_rejected_is_failure(self):
        # I2P/Local or a teardown failure: detach returns False, iface still up.
        self.transport.interfaces.append(FakeIface("relay1"))
        self.ret.detach_interface = lambda name: False
        res = self.ns["remove_interface"]("relay1")
        self.assertEqual(res, {"ok": False, "reason": "detach-failed"})


class HotInterfaceOpsSourceContractTest(unittest.TestCase):
    """The refactor must call RNS 1.5.5's PUBLIC attach/detach API. A structural
    AST check (call nodes, not docstring text) proves the code invokes
    `reticulum.attach_interface` / `reticulum.detach_interface`."""

    def _callee_calls(self, func_name):
        tree = ast.parse(BRIDGE.read_text())
        fn = next(n for n in tree.body
                  if isinstance(n, ast.FunctionDef) and n.name == func_name)
        callees = set()
        for node in ast.walk(fn):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                value = node.func.value
                if isinstance(value, ast.Name):
                    callees.add(f"{value.id}.{node.func.attr}")
        return callees

    def test_add_calls_public_attach_interface(self):
        self.assertIn("reticulum.attach_interface", self._callee_calls("add_interface"))

    def test_remove_calls_public_detach_interface(self):
        self.assertIn("reticulum.detach_interface", self._callee_calls("remove_interface"))


def _write_config(sections):
    import tempfile
    d = Path(tempfile.mkdtemp())
    lines = ["[global]", "network_name = test", "passphrase = x", "[interfaces]"]
    for s in sections:
        lines += [f"  [[{s}]]", "  type = TCPClient"]
    (d / "config").write_text("\n".join(lines) + "\n")
    return d


if __name__ == "__main__":
    unittest.main()
