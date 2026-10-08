"""The Python RNS node engine (the ``NodeEngine`` seam, Python half).

The engine-adapter seam (contract 15) is the ONLY surface a node owner uses to
reach a Reticulum implementation. This module is the **Python RNS** conformance:
it is deliberately thin - it does NOT reimplement RNS/LXMF. It maps the contract
surface (descriptor / capabilities / runtime snapshot / execute / capability gate)
onto the EXISTING ``app/rns_bridge.py`` operations (``start`` / ``send_opportunistic``
/ ``stop``), so the amount of custom Python running in the node owner is minimal
and the real Reticulum logic stays in the bridge.

It speaks the same wire dicts as ``control.py`` / ``canonical.py``: ``start``
returns a ``Descriptor`` dict, ``execute`` returns an ``EngineCommandResult`` dict,
``can_execute`` returns a ``NodeError`` dict or ``None``. The Swift node owner
(NE) hosts this via embedded CPython, does the durable store writes (contract 5:
single writer), and forwards the wire bytes over the ``[0xF5 0x02]`` channel.

Design for testability:
* The RNS bridge is INJECTED (``bridge`` arg). Production passes
  ``app.rns_bridge``; tests pass a fake exposing the same three functions. That
  means the mapping (contract -> bridge call -> wire dict) is fully provable on
  the Linux controller with NO RNS, while the Mac venv (RNS 1.5.3) proves it
  against the real runtime.
* Only the mandatory text-messaging vertical is advertised: ``durableMessaging``
  is ``supported``; every other feature is ``unsupported`` until its own
  conformance is proven (contract doc sequencing: do not advertise a feature
  before it is conformed). Fail-closed everywhere else.

Pure mapping only - no RNS import at module load, so this file builds and its
tests run on any CPython.
"""

from __future__ import annotations

import time
import uuid
from typing import Any, Dict, List, Optional

__all__ = [
    "PythonRNSNodeEngine",
    "ADAPTER_REVISION",
    "STORAGE_SCHEMA",
]

# Contract version this engine speaks (IDL {major:1, minor:0}).
CONTRACT_VERSION = {"major": 1, "minor": 0}
# The shared-store schema this engine writes/reads against (contract 5).
STORAGE_SCHEMA = 1
# Adapter revision (distinct from the RNS backend revision; bumped when the
# mapping changes). Tracked in the descriptor's backend.adapterRevision.
ADAPTER_REVISION = "1"

# The mandatory, conformed feature set for the first slice. Everything else is
# advertised unsupported (fail-closed) until it has its own conformance proof.
_SUPPORTED_FEATURES = {
    "durableMessaging": "supported",
}
# Features known to the engine but NOT yet conformed here.
_UNSUPPORTED_FEATURES = (
    "attachments",
    "replies",
    "reactions",
    "reactionRemoval",
    "extensionFields",
)


def _now_ms() -> int:
    return int(time.time() * 1000)


def _new_uuid() -> str:
    return str(uuid.uuid4())


def _cap(feature: str) -> Dict[str, Any]:
    """One capability dict in the exact Swift ``Capability`` wire shape."""
    support = _SUPPORTED_FEATURES.get(feature, "unsupported")
    availability = "available" if support == "supported" else "disabled"
    out: Dict[str, Any] = {
        "feature": feature,
        "support": support,
        "availability": availability,
    }
    if support != "supported":
        out["reason"] = "not conformed in this engine slice"
    return out


def _err(code: str, retry: str = "never", field: Optional[str] = None,
         detail: Optional[str] = None) -> Dict[str, Any]:
    """A NodeError dict in the exact Swift ``NodeError`` wire shape."""
    out: Dict[str, Any] = {"code": code, "retry": retry}
    if field is not None:
        out["field"] = field
    if detail is not None:
        out["detail"] = detail
    return out


class PythonRNSNodeEngine:
    """The Python RNS conformance of the ``NodeEngine`` seam.

    Constructed per node-owner boot with its RNS configuration (the config dir
    the app already wrote, the identity source, and the display name). ``start``
    brings RNS up through the injected bridge; ``execute`` drives an admitted
    ``submitMessage`` through ``send_opportunistic``.

    ``bridge`` must expose:
      * ``start(config_dir, identity_path, display_name, identity_bytes)``
        -> ``{"identity_hash": str, "destination_hash": str}``
      * ``send_opportunistic(dest_hash_hex, content, fields_hex, method,
        failure_fallback_method)`` -> ``{"ok": bool, "reason": str, ...}``
      * ``stop()`` -> None
    (These are the existing ``app.rns_bridge`` operations verbatim.)
    """

    def __init__(self, bridge: Any, config_dir: str,
                 identity_path: str = "",
                 display_name: str = "",
                 identity_bytes: Optional[bytes] = None) -> None:
        self._bridge = bridge
        self._config_dir = config_dir
        self._identity_path = identity_path
        self._display_name = display_name
        self._identity_bytes = identity_bytes
        self._started = False
        self._identity_hash: str = ""
        self._destination_hash: str = ""
        self._boot_id: str = _new_uuid()

    # ------------------------------------------------------------------ #
    # BuildInfo / capabilities (descriptor inputs)
    # ------------------------------------------------------------------ #

    def build_info(self) -> Dict[str, Any]:
        return {
            "name": "python-rns",
            "revision": self._rns_version(),
            "adapterRevision": ADAPTER_REVISION,
        }

    def capabilities(self) -> List[Dict[str, Any]]:
        caps = [_cap(f) for f in _SUPPORTED_FEATURES]
        caps += [_cap(f) for f in _UNSUPPORTED_FEATURES]
        return caps

    def _rns_version(self) -> str:
        """RNS version from the bridge if available, else 'unavailable' (Linux)."""
        rns = getattr(self._bridge, "RNS", None)
        if rns is not None and getattr(rns, "__version__", None):
            return str(rns.__version__)
        return "unavailable"

    # ------------------------------------------------------------------ #
    # Lifecycle
    # ------------------------------------------------------------------ #

    def start(self, store_epoch: str, boot_id: Optional[str] = None) -> Dict[str, Any]:
        """Bring the node up and return the ``Descriptor`` wire dict.

        Delegates to ``bridge.start`` (the real RNS boot + LXMF router + delivery
        identity + announce). On success we cache the local identity/destination
        hashes and report ``ready``.
        """
        if boot_id is not None:
            self._boot_id = boot_id
        info = self._bridge.start(
            self._config_dir,
            self._identity_path,
            self._display_name,
            self._identity_bytes,
        )
        self._identity_hash = info.get("identity_hash", "")
        self._destination_hash = info.get("destination_hash", "")
        self._started = True
        return self._descriptor(store_epoch)

    def _descriptor(self, store_epoch: str) -> Dict[str, Any]:
        identity_id = self._identity_hash  # transport identity == delivery hash
        return {
            "version": CONTRACT_VERSION,
            "storeEpoch": store_epoch,
            "bootID": self._boot_id,
            "storeSchema": STORAGE_SCHEMA,
            "capabilities": self.capabilities(),
            "backend": self.build_info(),
            "runtime": self._runtime_snapshot(identity_id),
        }

    def stop(self) -> None:
        """Tear down the node. Idempotent (bridge.stop is idempotent)."""
        if self._started:
            self._bridge.stop()
        self._started = False

    def runtime_snapshot(self) -> Dict[str, Any]:
        return self._runtime_snapshot(self._identity_hash)

    def _runtime_snapshot(self, identity_id: str) -> Dict[str, Any]:
        if not self._started:
            phase = "stopped"
            connectivity = "noInterfaces"
            actual_enabled = False
            enabled = []
        else:
            phase = "ready"
            # The bridge does not expose per-interface state; a started node with
            # a delivery identity is "interfacesAvailable" from the node owner's
            # point of view. (Refined per-interface state is a later slice.)
            connectivity = "interfacesAvailable"
            actual_enabled = True
            enabled = [identity_id] if identity_id else []
        return {
            "bootID": self._boot_id,
            "phase": phase,
            "desiredEnabled": True,
            "actualEnabled": actual_enabled,
            "enabledIdentities": enabled,
            "connectivity": connectivity,
            "observedAt": _now_ms(),
        }

    # ------------------------------------------------------------------ #
    # Capability gate (the admission policy calls this)
    # ------------------------------------------------------------------ #

    def can_execute(self, intent: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Return a NodeError dict if the engine cannot run ``intent`` now, else
        ``None``. This is the capability/scope gate the store's admission policy
        consults before it commits an accepted ledger disposition."""
        if not self._started:
            return _err("unavailable", retry="never",
                        detail="engine not started")
        tag = _command_tag(intent)
        if tag != "submitMessage":
            # Only the conformed text-messaging command runs in this slice.
            return _err("featureDisabled", retry="never",
                        detail=f"command {tag!r} not conformed in this engine slice")
        # durableMessaging is supported (see capabilities), so the command class
        # is allowed; scope (identity) is validated by the node owner / store.
        return None

    # ------------------------------------------------------------------ #
    # Execute (the actual side effect of an admitted command)
    # ------------------------------------------------------------------ #

    def execute(self, intent: Dict[str, Any]) -> Dict[str, Any]:
        """Execute an admitted command. Returns an ``EngineCommandResult`` dict:
        ``{"ok": True, "change": {...}|None}`` / ``{"ok": False, "interrupted":
        True}`` / ``{"ok": False, "error": {...}}``.

        ``submitMessage`` maps onto ``bridge.send_opportunistic``. The mapping of
        the LXMF result reasons is contract-significant:
          * ``queued``          -> ok, with an ``operation`` change (message_hash)
          * ``requesting-path`` -> interrupted (durable-resumable: no path yet,
                                    RNS is requesting one; not a committed reject)
          * ``not-started``     -> unavailable
          * ``bad-hash``        -> invalidArgument
          * ``no-propagation-node`` -> transportUnavailable (retryable after the
                                    propagation node is configured)
          * anything else       -> dependencyFailed
        """
        tag = _command_tag(intent)
        if tag != "submitMessage":
            return {
                "ok": False,
                "error": _err("featureDisabled", detail=f"cannot execute {tag!r}"),
            }

        value = _command_value(intent)
        dest_hex = value.get("destination", "")
        content = _inline_content(value.get("payload"))
        if content is None:
            return {
                "ok": False,
                "error": _err("unsupported", field="payload.content",
                              detail="non-inline content not conformed in this slice"),
            }
        method, fallback = _delivery_method(value.get("delivery"))

        result = self._bridge.send_opportunistic(
            dest_hex, content, "", method, fallback,
        )

        if not isinstance(result, dict):
            return {"ok": False, "error": _err("dependencyFailed")}

        if result.get("ok") and result.get("reason") == "queued":
            op_id = str(intent.get("commandID", _new_uuid()))
            message_hash = result.get("message_hash", "")
            return {
                "ok": True,
                "change": {
                    "entity": "operation",
                    "key": op_id,
                    "identityID": self._identity_hash or None,
                    "revision": 1,
                    "removed": False,
                    "detail": {"messageHash": message_hash},
                },
            }

        reason = result.get("reason", "")
        if reason == "requesting-path":
            return {"ok": False, "interrupted": True}
        if reason == "not-started":
            return {"ok": False, "error": _err("unavailable")}
        if reason == "bad-hash":
            return {"ok": False,
                    "error": _err("invalidArgument", field="destination",
                                  detail="malformed destination hash")}
        if reason == "no-propagation-node":
            return {"ok": False,
                    "error": _err("transportUnavailable",
                                  retry="afterStateChange",
                                  detail="propagation relay not configured")}
        return {"ok": False,
                "error": _err("dependencyFailed",
                              detail=f"send failed: {reason}")}


# ---------------------------------------------------------------------------
# Intent shape helpers (mirror the Swift tagged-union wire dicts)
# ---------------------------------------------------------------------------

def _command_tag(intent: Dict[str, Any]) -> str:
    body = intent.get("body", {})
    if isinstance(body, dict):
        return body.get("tag", "")
    return ""


def _command_value(intent: Dict[str, Any]) -> Dict[str, Any]:
    body = intent.get("body", {})
    if isinstance(body, dict):
        v = body.get("value")
        return v if isinstance(v, dict) else {}
    return {}


def _inline_content(payload: Any) -> Optional[str]:
    """Extract inline text content from a chat payload; None if not inline."""
    if not isinstance(payload, dict):
        return None
    if payload.get("tag") != "chat":
        return None
    value = payload.get("value")
    if not isinstance(value, dict):
        return None
    content = value.get("content")
    if not isinstance(content, dict) or content.get("tag") != "inline":
        return None
    return content.get("value", "")


def _delivery_method(delivery: Any) -> tuple:
    """Map the contract delivery block to (method, failure_fallback_method)."""
    if not isinstance(delivery, dict):
        return "opportunistic", ""
    preferred = delivery.get("preferred", "automatic")
    method = {
        "automatic": "opportunistic",
        "opportunistic": "opportunistic",
        "direct": "direct",
        "propagated": "propagated",
    }.get(preferred, "opportunistic")
    fallback = "propagated" if delivery.get("allowPropagationFallback") else ""
    return method, fallback
