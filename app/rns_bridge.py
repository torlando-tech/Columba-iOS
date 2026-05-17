"""rns_bridge — Python-side glue for Columba iOS PoC.

The Swift `PythonBridge` calls these module-level functions over the C-API
(via PyImport_ImportModule + PyObject_CallObject). Callbacks from Reticulum and
LXMF run on the RNS worker threads; rather than wire C-callable function pointers
across the Swift/Python boundary, we drop events onto a thread-safe queue that
Swift drains on a timer. Single-threaded simple, no GIL juggling for callbacks.

Scope: TCPClientInterface only, lxmf.delivery announces, opportunistic LXMF only.
"""

from __future__ import annotations

import os
import queue
import threading
import time
from typing import Any

import sys

# Redirect Python stdout/stderr to NSLog via os.write to the simulator's stderr fd,
# which Xcode captures and `simctl spawn log stream` surfaces. Without this, RNS.log()
# output goes to a logfile inside the sandbox that's awkward to tail mid-run.
class _SysLogStream:
    def __init__(self, prefix: str):
        self.prefix = prefix
        self.buf = ""
    def write(self, s: str) -> int:
        if not isinstance(s, str): s = str(s)
        self.buf += s
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            sys.__stderr__.write(f"[{self.prefix}] {line}\n")
            sys.__stderr__.flush()
        return len(s)
    def flush(self) -> None:
        if self.buf:
            sys.__stderr__.write(f"[{self.prefix}] {self.buf}\n")
            sys.__stderr__.flush()
            self.buf = ""

sys.stdout = _SysLogStream("py-stdout")
# stderr is left raw so Python tracebacks remain unfiltered.

import RNS
import LXMF


_lock = threading.Lock()
_events: "queue.Queue[dict]" = queue.Queue()
_state: dict[str, Any] = {
    "started": False,
    "reticulum": None,
    "router": None,
    "identity": None,
    "destination": None,
    "handler": None,
    "config_dir": None,
}


def _put(kind: str, **payload: Any) -> None:
    payload["kind"] = kind
    payload["t"] = time.time()
    _events.put(payload)


class _AspectAnnounceHandler:
    """Per-aspect announce handler. RNS lets you register multiple of these,
    each scoped to one `aspect_filter` — we register one for each of the four
    aspects the Columba UI surfaces (LXMF delivery, LXMF propagation,
    NomadNet node, LXST telephony) so the Network tab can show all of them
    side-by-side with the right badge / filter chip."""

    receive_path_responses = True

    def __init__(self, aspect: str):
        self.aspect_filter = aspect
        self._aspect = aspect

    def received_announce(
        self,
        destination_hash: bytes,
        announced_identity: "RNS.Identity",
        app_data: bytes | None,
    ) -> None:
        display_name = _decode_announce_app_data(app_data)
        public_keys_hex = ""
        try:
            pub = getattr(announced_identity, "get_public_key", None)
            if callable(pub):
                public_keys_hex = pub().hex()
        except Exception:
            pass
        _put(
            "announce",
            dest_hash=destination_hash.hex(),
            display_name=display_name,
            aspect=self._aspect,
            public_keys=public_keys_hex,
        )


# Aspects the Columba UI surfaces. Order matters: when the same destination
# announces under multiple aspects we'll emit one event per aspect.
_TRACKED_ASPECTS = (
    "lxmf.delivery",
    "lxmf.propagation",
    "nomadnetwork.node",
    "lxst.telephony",
)


def _decode_announce_app_data(app_data: bytes | None) -> str:
    """LXMF announce app_data is msgpack-packed [display_name_bytes, stamp_cost].
    Older clients may send raw UTF-8 bytes — fall back to that on decode failure.
    See LXMF.LXMRouter.get_announce_app_data."""
    if not app_data:
        return ""
    try:
        from RNS.vendor import umsgpack
        decoded = umsgpack.unpackb(app_data)
        if isinstance(decoded, (list, tuple)) and decoded and decoded[0] is not None:
            name = decoded[0]
            if isinstance(name, bytes):
                return name.decode("utf-8", errors="replace")
            return str(name)
    except Exception:
        pass
    try:
        return app_data.decode("utf-8", errors="replace")
    except Exception:
        return ""


def _delivery_callback(message: "LXMF.LXMessage") -> None:
    """Fires for every inbound LXMF message routed to our delivery destination."""
    try:
        content = message.content_as_string()
    except Exception:
        content = ""
    try:
        title = message.title_as_string()
    except Exception:
        title = ""
    src = message.source_hash.hex() if message.source_hash else ""
    _put("inbound", source_hash=src, content=content, title=title)


def start(
    config_dir: str,
    identity_path: str,
    display_name: str,
    identity_bytes: bytes | None = None,
) -> dict[str, str]:
    """Initialize Reticulum + LXMRouter. Idempotent — returns local_info if already up.

    The RNS config file at `<config_dir>/config` must already exist — Swift
    writes it from the user's `InterfaceEntity` records before calling
    `start()`. See `PythonConfigWriter.swift`. If the config file is missing,
    Reticulum will fall back to its default behavior (create a default
    config and try to auto-discover interfaces).

    Identity precedence (highest first):
      1. `identity_bytes` — raw 64-byte private key blob (preferred path for iOS;
         Swift reads it from Keychain and hands it over). Identity is loaded via
         RNS.Identity.from_bytes() and never touches the filesystem.
      2. `identity_path` — existing file on disk; loaded via RNS.Identity.from_file().
      3. Neither — generate a fresh identity and persist to `identity_path` (PoC
         and CLI use; iOS production should never hit this branch since the
         Keychain entry is created on first launch by Swift)."""
    with _lock:
        if _state["started"]:
            return _local_info()

        os.makedirs(config_dir, exist_ok=True)
        _state["config_dir"] = config_dir

        # Both RNS.Reticulum.__init__ and LXMF.LXMRouter.__init__ call signal.signal()
        # for SIGINT/SIGTERM. That requires Python's main thread; we're on a Swift
        # dispatch queue, so the call raises ValueError. iOS apps don't receive these
        # signals (UIKit handles app lifecycle), so stubbing them is safe.
        import signal as _signal
        _orig_signal = _signal.signal
        _signal.signal = lambda *_a, **_kw: None
        try:
            reticulum = RNS.Reticulum(config_dir)
            _state["reticulum"] = reticulum

            if identity_bytes is not None and len(identity_bytes) > 0:
                identity = RNS.Identity.from_bytes(identity_bytes)
                if identity is None:
                    raise RuntimeError("Failed to load identity from supplied bytes")
            elif os.path.isfile(identity_path):
                identity = RNS.Identity.from_file(identity_path)
                if identity is None:
                    raise RuntimeError(f"Failed to load identity at {identity_path}")
            else:
                identity = RNS.Identity()
                identity.to_file(identity_path)
            _state["identity"] = identity

            storage_path = os.path.join(config_dir, "lxmf-storage")
            os.makedirs(storage_path, exist_ok=True)
            router = LXMF.LXMRouter(identity=identity, storagepath=storage_path)
            router.register_delivery_callback(_delivery_callback)
            _state["router"] = router
        finally:
            _signal.signal = _orig_signal

        delivery_destination = router.register_delivery_identity(
            identity, display_name=display_name
        )
        if delivery_destination is None:
            raise RuntimeError("register_delivery_identity returned None")
        _state["destination"] = delivery_destination

        handlers = []
        for aspect in _TRACKED_ASPECTS:
            h = _AspectAnnounceHandler(aspect)
            RNS.Transport.register_announce_handler(h)
            handlers.append(h)
        _state["handler"] = handlers  # list now, was singleton — stop() handles both

        # Register the lxst.telephony destination on our identity so
        # incoming voice calls have somewhere to land. Inbound RNS.Link
        # establishment on this destination emits a `link_state` event
        # tagged with a fresh link_id; the Swift side (CallManager →
        # lxst-swift Telephone) takes over from there.
        global _telephony_destination
        try:
            _telephony_destination = RNS.Destination(
                identity, RNS.Destination.IN, RNS.Destination.SINGLE,
                "lxst", "telephony"
            )

            def _on_inbound_link(link: Any) -> None:
                link_id = _alloc_link_id()
                with _lock:
                    _links[link_id] = link
                _wire_link_callbacks(link, link_id)
                # The "established" callback fires only on outbound
                # links — inbound links arrive already established, so
                # synthesize the event manually so the Swift side sees
                # one matching state transition either way.
                _put("link_state", link_id=link_id, state="established", inbound=True)

            _telephony_destination.set_link_established_callback(_on_inbound_link)
            _state["telephony_destination"] = _telephony_destination
        except Exception as e:
            _put("state", value=f"telephony-register-failed: {e}")

        # Announce ourselves so the network knows where we are. We re-announce
        # after a short delay because the TCP interface needs ~1-2s to come
        # online; the first announce can be dropped if the interface isn't
        # connected yet.
        delivery_destination.announce()

        def _delayed_reannounce() -> None:
            for delay in (2, 5, 15, 30):
                time.sleep(delay)
                try:
                    delivery_destination.announce()
                except Exception:
                    pass

        threading.Thread(target=_delayed_reannounce, daemon=True).start()

        _state["started"] = True
        _put("state", value="connected")
        return _local_info()


def set_propagation_node(dest_hash_hex: str, stamp_cost: int = 0) -> dict[str, Any]:
    """Configure which LXMF propagation node this client uses for store-and-
    forward retrieval. `dest_hash_hex` must be the destination hash of an
    `lxmf.propagation` announce we've already received (or empty string to
    clear the selection)."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        router = _state["router"]
        if router is None:
            return {"ok": False, "reason": "no-router"}
        try:
            if dest_hash_hex:
                dest_hash = bytes.fromhex(dest_hash_hex)
                router.set_outbound_propagation_node(dest_hash)
                if hasattr(router, "set_propagation_node_stamp_cost"):
                    router.set_propagation_node_stamp_cost(int(stamp_cost))
            else:
                # Clear selection — pass None / 0 to drop both the node
                # and the stamp cost.
                router.set_outbound_propagation_node(None)
                if hasattr(router, "set_propagation_node_stamp_cost"):
                    router.set_propagation_node_stamp_cost(0)
        except Exception as e:
            return {"ok": False, "reason": f"set-failed: {e}"}
        return {"ok": True, "reason": "ok"}


def propagation_sync(timeout: float = 60.0) -> dict[str, Any]:
    """Block until the current LXMF propagation-node sync finishes (or
    times out). Returns `{ok, state, received_messages, reason}`.

    `state` mirrors LXMRouter.PR_* (e.g. `complete`, `no_path`,
    `transfer_failed`, `path_requested`, `link_established`,
    `receiving`). `received_messages` is the count of new inbound
    LXMessages that landed on the local delivery destination during
    this sync.

    Requires set_propagation_node() to have been called with a valid
    `lxmf.propagation` destination first."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "state": "not-started", "received_messages": 0, "reason": "not-started"}
        router = _state["router"]
        identity = _state["identity"]
        if router is None or identity is None:
            return {"ok": False, "state": "no-router", "received_messages": 0, "reason": "no-router"}
        outbound = getattr(router, "outbound_propagation_node", None)
        if outbound is None:
            return {"ok": False, "state": "no-node", "received_messages": 0, "reason": "no-node-selected"}

        try:
            router.request_messages_from_propagation_node(identity)
        except Exception as e:
            return {"ok": False, "state": "transfer-failed", "received_messages": 0, "reason": f"start-failed: {e}"}

    # Poll the router state outside the lock so the router can update
    # propagation_transfer_state from its own thread.
    deadline = time.monotonic() + timeout
    last_seen_state: Any = None
    while time.monotonic() < deadline:
        try:
            state_val = getattr(router, "propagation_transfer_state", None)
            last_seen_state = state_val
            terminal = {
                getattr(LXMF.LXMRouter, "PR_COMPLETE", 5),
                getattr(LXMF.LXMRouter, "PR_NO_PATH", 6),
                getattr(LXMF.LXMRouter, "PR_TRANSFER_FAILED", 7),
                getattr(LXMF.LXMRouter, "PR_LINK_ESTABLISHED", 99),  # placeholder if absent
            }
            # Only PR_COMPLETE / PR_NO_PATH / PR_TRANSFER_FAILED are
            # truly terminal — link-established is intermediate.
            real_terminal = {
                getattr(LXMF.LXMRouter, "PR_COMPLETE", 5),
                getattr(LXMF.LXMRouter, "PR_NO_PATH", 6),
                getattr(LXMF.LXMRouter, "PR_TRANSFER_FAILED", 7),
            }
            if state_val in real_terminal:
                break
        except Exception:
            pass
        time.sleep(0.5)

    received = 0
    try:
        received = int(getattr(router, "propagation_transfer_last_result", 0) or 0)
    except Exception:
        pass

    state_name = _propagation_state_name(last_seen_state)
    ok = state_name == "complete"
    return {
        "ok": ok,
        "state": state_name,
        "received_messages": received,
        "reason": "ok" if ok else state_name,
    }


def _propagation_state_name(val: Any) -> str:
    if val is None:
        return "idle"
    # LXMF.LXMRouter PR_* constants → lowercase names. Use getattr so the
    # mapping stays correct even if the upstream enum gets reordered.
    mapping = {
        getattr(LXMF.LXMRouter, "PR_IDLE", -1): "idle",
        getattr(LXMF.LXMRouter, "PR_PATH_REQUESTED", -2): "path_requested",
        getattr(LXMF.LXMRouter, "PR_LINK_ESTABLISHING", -3): "link_establishing",
        getattr(LXMF.LXMRouter, "PR_LINK_ESTABLISHED", -4): "link_established",
        getattr(LXMF.LXMRouter, "PR_REQUEST_SENT", -5): "request_sent",
        getattr(LXMF.LXMRouter, "PR_RECEIVING", -6): "receiving",
        getattr(LXMF.LXMRouter, "PR_RESPONSE_RECEIVED", -7): "response_received",
        getattr(LXMF.LXMRouter, "PR_COMPLETE", -8): "complete",
        getattr(LXMF.LXMRouter, "PR_NO_PATH", -9): "no_path",
        getattr(LXMF.LXMRouter, "PR_TRANSFER_FAILED", -10): "transfer_failed",
    }
    return mapping.get(val, f"state_{val}")


# ────────────────────────────────────────────────────────────────────
# RNS.Link bridge — used by lxst-swift for voice calls.
#
# Audio frames stay on the Swift side end-to-end (capture / encode in
# AVAudioEngine + libopus, decode / playback symmetrically). Python's
# only job is to handle the underlying RNS.Link cryptography +
# framing + routing — opaque byte payloads flow in both directions via
# the event queue (link_packet) and `link_send`.
#
# Mirrors the lxst-kt Kotlin port that Columba Android uses on its
# native (non-Chaquopy) voice path. Swift is the LXST protocol owner;
# Python is just "Link as a pipe".
# ────────────────────────────────────────────────────────────────────

_links: dict[int, Any] = {}        # link_id -> RNS.Link
_next_link_id_counter = 0
_telephony_destination: Any = None  # RNS.Destination for lxst.telephony aspect


def _alloc_link_id() -> int:
    global _next_link_id_counter
    _next_link_id_counter += 1
    return _next_link_id_counter


def _wire_link_callbacks(link: Any, link_id: int) -> None:
    """Hook the standard set of Link callbacks (established / closed /
    packet / remote_identified) so the Swift side receives matching
    events on the drain queue."""
    def _on_established(_l: Any) -> None:
        _put("link_state", link_id=link_id, state="established")

    def _on_closed(l: Any) -> None:
        reason = ""
        try:
            tr = getattr(l, "teardown_reason", None)
            reason = str(tr) if tr is not None else ""
        except Exception:
            pass
        _put("link_state", link_id=link_id, state="closed", reason=reason)
        with _lock:
            _links.pop(link_id, None)

    def _on_packet(data: bytes, _packet: Any) -> None:
        try:
            _put("link_packet", link_id=link_id, data_hex=data.hex() if data else "")
        except Exception:
            pass

    def _on_remote_identified(_l: Any, identity: Any) -> None:
        try:
            _put(
                "link_identified",
                link_id=link_id,
                identity_hash=identity.hash.hex() if identity is not None else "",
            )
        except Exception:
            pass

    link.set_link_established_callback(_on_established)
    link.set_link_closed_callback(_on_closed)
    link.set_packet_callback(_on_packet)
    try:
        # RNS uses one of these two names depending on version
        link.set_remote_identified_callback(_on_remote_identified)
    except AttributeError:
        try:
            link.set_remote_identification_callback(_on_remote_identified)
        except AttributeError:
            pass


def open_link(dest_hash_hex: str, aspect: str = "lxst.telephony") -> dict[str, Any]:
    """Initiate an outbound RNS.Link to a destination with the given
    aspect (default `lxst.telephony` for voice). Returns a link_id
    Swift can use to send/teardown/identify on the link.

    Returns:
      {ok: bool, link_id: int, reason: str}

    Reasons:
      ok           — link initiated; subsequent link_state event will
                     fire `established` or `closed`
      not-started  — Python RNS hasn't been started yet
      bad-hash     — dest_hash_hex isn't a valid hex string
      no-path      — Identity hasn't been recalled; a request_path was
                     kicked off; caller should retry once we receive
                     an announce for `dest_hash`
    """
    with _lock:
        if not _state["started"]:
            return {"ok": False, "link_id": 0, "reason": "not-started"}
    try:
        dest_hash = bytes.fromhex(dest_hash_hex)
    except ValueError:
        return {"ok": False, "link_id": 0, "reason": "bad-hash"}

    peer_identity = RNS.Identity.recall(dest_hash)
    if peer_identity is None:
        try:
            RNS.Transport.request_path(dest_hash)
        except Exception:
            pass
        return {"ok": False, "link_id": 0, "reason": "no-path"}

    # Split the dotted aspect into app_name + remaining aspect tokens
    # (RNS.Destination's variadic aspects parameter).
    parts = aspect.split(".") if aspect else ["lxst", "telephony"]
    app_name = parts[0]
    aspects = parts[1:] if len(parts) > 1 else []

    peer_dest = RNS.Destination(
        peer_identity, RNS.Destination.OUT, RNS.Destination.SINGLE,
        app_name, *aspects
    )
    try:
        link = RNS.Link(peer_dest)
    except Exception as e:
        return {"ok": False, "link_id": 0, "reason": f"link-init-failed: {e}"}

    link_id = _alloc_link_id()
    _wire_link_callbacks(link, link_id)
    with _lock:
        _links[link_id] = link
    _put("link_state", link_id=link_id, state="establishing")
    return {"ok": True, "link_id": link_id, "reason": "ok"}


def link_send(link_id: int, data_hex: str) -> dict[str, Any]:
    """Send opaque bytes over an established Link. `data_hex` is the
    hex-encoded payload (Swift hex-encodes the byte buffer before
    calling). The bytes get wrapped in a single RNS.Packet.

    Returns {ok, reason}. Reasons: ok / not-started / no-link /
    not-established / bad-hex / send-failed."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        link = _links.get(int(link_id))
        if link is None:
            return {"ok": False, "reason": "no-link"}

    if not getattr(link, "status", None) == RNS.Link.ACTIVE:
        # Allow PENDING too if the caller knows what they're doing,
        # but reject CLOSED / FAILED.
        if getattr(link, "status", None) == RNS.Link.CLOSED:
            return {"ok": False, "reason": "closed"}

    try:
        data = bytes.fromhex(data_hex)
    except ValueError:
        return {"ok": False, "reason": "bad-hex"}

    try:
        # RNS.Packet(link, data).send() is the canonical way to send
        # opaque bytes over a Link — wraps them in a Link packet that
        # the remote receives via the Link's packet callback.
        packet = RNS.Packet(link, data)
        packet.send()
    except Exception as e:
        return {"ok": False, "reason": f"send-failed: {e}"}
    return {"ok": True, "reason": "ok"}


def link_identify(link_id: int) -> dict[str, Any]:
    """Reveal our identity on the given Link to the remote (so the
    remote's `link_identified` event fires with our identity hash).
    Mirrors `link.identify(local_identity)` from Python RNS."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        link = _links.get(int(link_id))
        local_identity = _state["identity"]
        if link is None:
            return {"ok": False, "reason": "no-link"}
        if local_identity is None:
            return {"ok": False, "reason": "no-identity"}
    try:
        link.identify(local_identity)
    except Exception as e:
        return {"ok": False, "reason": f"identify-failed: {e}"}
    return {"ok": True, "reason": "ok"}


def link_teardown(link_id: int) -> dict[str, Any]:
    """Tear down a Link from our side. The closed_callback will fire
    on both peers (which emits a `link_state=closed` event)."""
    with _lock:
        link = _links.pop(int(link_id), None)
    if link is None:
        return {"ok": False, "reason": "no-link"}
    try:
        link.teardown()
    except Exception:
        pass
    return {"ok": True, "reason": "ok"}


def announce(display_name: str = "") -> dict[str, Any]:
    """Re-broadcast the LXMF delivery destination's announce with optional
    display name update. Called from the Settings UI's manual "Announce"
    button and from the AutoAnnounceManager timer.

    Updates `delivery_destination.app_data` to the new display name
    (msgpack-packed [name_bytes, stamp_cost] per LXMF's announce format
    — matches LXMRouter.get_announce_app_data) so peers see the latest
    name. Then calls `.announce()` which queues the announce packet for
    every online interface.

    Returns `{ok: bool, reason: str}`. `not-started` when Python hasn't
    booted yet, `no-destination` when register_delivery_identity failed
    earlier in start(), `ok` on success."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        destination = _state["destination"]
        if destination is None:
            return {"ok": False, "reason": "no-destination"}

        # LXMF expects app_data as msgpack-packed [name: bytes, stamp_cost: int].
        # display_name="" still announces — peers will fall back to the
        # short-hex shortHash for their UI.
        try:
            from RNS.vendor import umsgpack
            name_bytes = display_name.encode("utf-8", errors="replace")
            destination.set_default_app_data(umsgpack.packb([name_bytes, 0]))
        except Exception as e:
            return {"ok": False, "reason": f"appdata-error: {e}"}

        try:
            destination.announce()
        except Exception as e:
            return {"ok": False, "reason": f"announce-error: {e}"}
        return {"ok": True, "reason": "ok"}


def announce_telephony(display_name: str = "") -> dict[str, Any]:
    """Re-broadcast the LXST telephony destination's announce so peers can
    discover us for voice calls. Mirrors `announce()` but targets the
    `_telephony_destination` instead of the LXMF delivery destination.

    The app data is the raw UTF-8 display name (no msgpack wrapper) — the
    AnnounceHandler on the Swift side decodes it as a plain string for the
    Network tab. Matches what Sideband / canonical LXST do."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        destination = _telephony_destination
        if destination is None:
            return {"ok": False, "reason": "no-telephony-destination"}

        try:
            destination.set_default_app_data(
                display_name.encode("utf-8", errors="replace")
            )
        except Exception as e:
            return {"ok": False, "reason": f"appdata-error: {e}"}

        try:
            destination.announce()
        except Exception as e:
            return {"ok": False, "reason": f"announce-error: {e}"}
        return {"ok": True, "reason": "ok"}


def stop() -> None:
    with _lock:
        if not _state["started"]:
            return
        try:
            existing = _state["handler"]
            if existing is not None:
                handlers_to_drop = existing if isinstance(existing, list) else [existing]
                for h in handlers_to_drop:
                    try:
                        RNS.Transport.deregister_announce_handler(h)
                    except Exception:
                        pass
        except Exception:
            pass
        try:
            if _state["router"] is not None:
                _state["router"].exit_handler()
        except Exception:
            pass
        try:
            if _state["reticulum"] is not None:
                _state["reticulum"].exit_handler()
        except Exception:
            pass

        # RNS.Reticulum is a singleton: its __init__ raises OSError("Attempt to
        # reinitialise Reticulum, when it was already running") if the class-level
        # __instance is still set. exit_handler() does not clear it, so
        # reconnect-after-disconnect explodes. Clear the mangled class attrs
        # ourselves. Same for the exit-handler flags so a fresh init re-runs them.
        try:
            RNS.Reticulum._Reticulum__instance = None
            RNS.Reticulum._Reticulum__exit_handler_ran = False
            RNS.Reticulum._Reticulum__interface_detach_ran = False
        except Exception:
            pass

        # RNS.Transport.destinations is a class-level list of every Destination
        # ever registered with this Python process. exit_handler() doesn't drain
        # it, so a subsequent register_delivery_identity() in a fresh LXMRouter
        # raises "Attempt to register an already registered destination." Clear
        # the list (and the cohort of Transport class-level state we wrote to
        # during this run) so the next start sees a clean slate.
        try:
            RNS.Transport.destinations = []
        except Exception:
            pass
        try:
            RNS.Transport.interfaces = []
        except Exception:
            pass
        try:
            RNS.Transport.path_table = {}
        except Exception:
            pass
        try:
            RNS.Transport.destination_table = {}
        except Exception:
            pass
        try:
            RNS.Transport.announce_handlers = []
        except Exception:
            pass
        try:
            RNS.Transport.identities = {}
        except Exception:
            pass

        # Restore log level (exit_handler sets RNS.loglevel = LOG_NONE) so the
        # next init's RNS.log() calls are visible again.
        try:
            RNS.loglevel = RNS.LOG_VERBOSE
        except Exception:
            pass

        # Tear down any open RNS.Links and forget the telephony
        # destination so a subsequent start() doesn't trip on stale
        # callbacks pointing at a freed RNS.Transport.
        global _telephony_destination
        for lid, link in list(_links.items()):
            try:
                link.teardown()
            except Exception:
                pass
        _links.clear()
        _telephony_destination = None

        # Drop registered BLE callbacks so a subsequent start() doesn't
        # invoke closures bound to the previous driver / Swift bridge.
        clear_ble_callbacks()
        global _ble_bridge_handle
        _ble_bridge_handle = None

        _state.update({
            "started": False,
            "reticulum": None,
            "router": None,
            "identity": None,
            "destination": None,
            "handler": None,
            "telephony_destination": None,
        })
        _put("state", value="disconnected")


def send_opportunistic(dest_hash_hex: str, content: str) -> dict[str, Any]:
    """Send an opportunistic LXMF message. Returns a dict with 'ok' (bool)
    and 'reason' (string) describing the outcome. If the destination's
    identity isn't recallable yet (no announce / no path), kicks off a
    `request_path` and returns ok=False reason='requesting-path'."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        router = _state["router"]
        local_dest = _state["destination"]
        try:
            dest_hash = bytes.fromhex(dest_hash_hex)
        except ValueError:
            return {"ok": False, "reason": "bad-hash"}

        peer_identity = RNS.Identity.recall(dest_hash)
        if peer_identity is None:
            try:
                RNS.Transport.request_path(dest_hash)
            except Exception:
                pass
            return {"ok": False, "reason": "requesting-path"}

        peer_dest = RNS.Destination(
            peer_identity,
            RNS.Destination.OUT,
            RNS.Destination.SINGLE,
            "lxmf",
            "delivery",
        )
        msg = LXMF.LXMessage(
            peer_dest,
            local_dest,
            content,
            title="",
            desired_method=LXMF.LXMessage.OPPORTUNISTIC,
        )
        router.handle_outbound(msg)
        return {"ok": True, "reason": "queued"}


def fetch_nomadnet_page(
    dest_hash_hex: str,
    path: str,
    timeout: float = 30.0,
    form_fields: dict[str, str] | None = None,
) -> dict[str, Any]:
    """One-shot fetch of a NomadNet page over an RNS Link.

    Walks the full RNS request cycle synchronously so the Swift caller
    doesn't have to manage Link / RequestReceipt lifecycles. Returns
    `{ok, status, data, content_type}` where:

      - ok: True on success
      - status: short string ('ok' | 'no-identity' | 'no-path' |
        'link-failed' | 'request-failed' | 'timeout')
      - data: bytes (Micron markup or arbitrary file payload), or
        empty bytes on failure
      - content_type: optional mime hint when the server provides one

    `form_fields` is a `dict[str, str]` (form name -> value) for
    POST-style submissions; pass `None` for a plain GET-equivalent
    fetch. Form values are passed as msgpack to match Reticulum's
    convention. Link is established fresh each call and closed
    before return — no link caching on the Python side yet (Swift's
    NomadNetBrowserService used to cache, but with this simplified
    bridge we trade a few hundred ms of re-establishment for a much
    smaller API surface)."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "status": "not-started", "data": b"", "content_type": ""}
    try:
        dest_hash = bytes.fromhex(dest_hash_hex)
    except ValueError:
        return {"ok": False, "status": "bad-hash", "data": b"", "content_type": ""}

    # Recall the remote identity. If we haven't received an announce yet,
    # kick off a request_path and bail — caller can retry once the path
    # arrives. (Mirrors send_opportunistic's behavior.)
    peer_identity = RNS.Identity.recall(dest_hash)
    if peer_identity is None:
        try:
            RNS.Transport.request_path(dest_hash)
        except Exception:
            pass
        return {"ok": False, "status": "no-path", "data": b"", "content_type": ""}

    peer_dest = RNS.Destination(
        peer_identity,
        RNS.Destination.OUT,
        RNS.Destination.SINGLE,
        "nomadnetwork",
        "node",
    )

    # Use threading.Event for synchronous waits on the async RNS callbacks.
    link_ready = threading.Event()
    link_closed = threading.Event()
    response_ready = threading.Event()
    state = {
        "response_data": None,
        "response_error": None,
        "link_close_reason": None,
    }

    def _on_link_established(_link: Any) -> None:
        link_ready.set()

    def _on_link_closed(link: Any) -> None:
        try:
            state["link_close_reason"] = getattr(link, "teardown_reason", None)
        except Exception:
            pass
        link_closed.set()
        # If we were waiting for a response when the link died, unblock.
        response_ready.set()

    def _on_response(request_receipt: Any) -> None:
        try:
            state["response_data"] = request_receipt.response
        except Exception as e:
            state["response_error"] = f"response-extract-failed: {e}"
        response_ready.set()

    def _on_failed(_request_receipt: Any) -> None:
        state["response_error"] = "request-failed"
        response_ready.set()

    link = RNS.Link(peer_dest, established_callback=_on_link_established, closed_callback=_on_link_closed)
    # We need to identify on the link so the remote knows who we are; nomadnet's
    # node app expects it for stateful pages.
    try:
        if _state["identity"] is not None:
            link.identify(_state["identity"])
    except Exception:
        pass

    if not link_ready.wait(timeout=min(20.0, timeout)):
        try:
            link.teardown()
        except Exception:
            pass
        return {"ok": False, "status": "link-failed", "data": b"", "content_type": ""}

    # Pack form fields as msgpack when present (Reticulum/LXMF convention).
    request_data: Any = None
    if form_fields:
        try:
            from RNS.vendor import umsgpack
            request_data = umsgpack.packb(dict(form_fields))
        except Exception:
            # Fall back to nothing — better to send the request unform'd
            # than to fail outright.
            request_data = None

    try:
        link.request(
            path,
            data=request_data,
            response_callback=_on_response,
            failed_callback=_on_failed,
            timeout=timeout,
        )
    except Exception as e:
        try:
            link.teardown()
        except Exception:
            pass
        return {"ok": False, "status": "request-failed", "data": b"", "content_type": str(e)}

    if not response_ready.wait(timeout=timeout):
        try:
            link.teardown()
        except Exception:
            pass
        return {"ok": False, "status": "timeout", "data": b"", "content_type": ""}

    try:
        link.teardown()
    except Exception:
        pass

    if state["response_error"]:
        return {"ok": False, "status": "request-failed", "data": b"", "content_type": state["response_error"]}

    response = state["response_data"]
    if response is None:
        return {"ok": False, "status": "request-failed", "data": b"", "content_type": "empty-response"}

    # NomadNet wraps payloads in msgpack as [page_data, [files]] for resource
    # responses, or just raw bytes for short responses. Unwrap if it looks
    # msgpack-packed; otherwise return as-is.
    payload = response
    if isinstance(response, (bytes, bytearray)):
        payload = bytes(response)
    elif isinstance(response, str):
        payload = response.encode("utf-8", errors="replace")
    elif isinstance(response, (list, tuple)) and len(response) >= 1:
        first = response[0]
        if isinstance(first, (bytes, bytearray)):
            payload = bytes(first)
        elif isinstance(first, str):
            payload = first.encode("utf-8", errors="replace")
        else:
            payload = b""
    else:
        payload = b""

    return {"ok": True, "status": "ok", "data": payload, "content_type": ""}


def reset_identity(identity_path: str) -> None:
    """Delete identity bytes on disk and tear down state. Caller must call
    start() again after this. Safe to call when not started."""
    with _lock:
        try:
            if _state["reticulum"] is not None:
                _state["reticulum"].exit_handler()
        except Exception:
            pass
        _state.update({
            "started": False,
            "reticulum": None,
            "router": None,
            "identity": None,
            "destination": None,
            "handler": None,
        })
    try:
        if os.path.isfile(identity_path):
            os.remove(identity_path)
    except OSError:
        pass


def _local_info() -> dict[str, str]:
    identity = _state["identity"]
    destination = _state["destination"]
    return {
        "identity_hash": identity.hash.hex() if identity is not None else "",
        "destination_hash": destination.hash.hex() if destination is not None else "",
    }


def local_info() -> dict[str, str]:
    with _lock:
        return _local_info()


def status() -> dict[str, Any]:
    """Introspect RNS Transport state. Returns interface list w/ online status,
    path-table size, announce-queue size."""
    with _lock:
        out: dict[str, Any] = {"started": _state["started"]}
        try:
            interfaces = RNS.Transport.interfaces
            iface_info = []
            for iface in interfaces:
                # `iface.name` is the config section name (e.g.
                # "Smoke_Test_Hub-smoke-"); str(iface) is the friendly
                # "TCPInterface[name/host:port]" form. Swift matches by
                # section name to update the TCPInterface stub's state.
                iface_info.append({
                    "section_name": getattr(iface, "name", ""),
                    "name": str(iface),
                    "online": bool(getattr(iface, "online", False)),
                    "ifac_size": getattr(iface, "ifac_size", None),
                    "rx_bytes": getattr(iface, "rxb", 0),
                    "tx_bytes": getattr(iface, "txb", 0),
                })
            out["interfaces"] = iface_info
        except Exception as e:
            out["interfaces_error"] = str(e)
        try:
            out["destination_table_size"] = len(RNS.Transport.destination_table)
        except Exception:
            out["destination_table_size"] = -1
        try:
            out["path_table_size"] = len(RNS.Transport.path_table)
        except Exception:
            out["path_table_size"] = -1
        return out


def status_json() -> str:
    """JSON-serialized form of `status()` for the Swift bridge to parse.
    Avoids round-tripping a Python dict through the C API one PyObject at
    a time — Swift just calls `json.JSONDecoder.decode(...)`."""
    import json as _json
    return _json.dumps(status())


def drain_events() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    while True:
        try:
            out.append(_events.get_nowait())
        except queue.Empty:
            break
    return out


# ────────────────────────────────────────────────────────────────────
# BLE bridge: registry for Swift→Python callbacks + handle to the
# Swift `SwiftBLEBridge` instance that the Python driver
# (`ios_ble_driver.IOSBLEDriver`) calls into.
#
# Direction matrix:
#   Swift → Python (sync):     PythonBridge.invokeBLECallback / -BoolSync
#                              looks up callables via `_ble_get_callback`
#                              and calls them under the GIL.
#   Python → Swift (sync):     Driver calls C-ABI shims exported by
#                              SwiftBLEBridge via ctypes (wired in Phase 3).
# ────────────────────────────────────────────────────────────────────

_ble_callbacks: dict[str, Any] = {}
_ble_bridge_handle: Any = None


def set_ble_bridge(handle: Any) -> None:
    """Hand the SwiftBLEBridge instance handle to Python. Called from Swift's
    `AppServices.startBLEInterface()` after the Swift bridge is constructed.
    The IOSBLEDriver reads this on its first `start()` call so it knows where
    to route outbound commands.

    `handle` is opaque to Python (currently a PyCapsule wrapping a Swift
    object pointer); the ctypes shims in `ios_ble_driver.py` don't need it
    because `ctypes.CDLL(None)` resolves through the process's symbol table.
    Stashed here so future driver code that does need a per-bridge handle
    can find it without a re-init."""
    global _ble_bridge_handle
    _ble_bridge_handle = handle


def get_ble_bridge() -> Any:
    """Driver-side accessor for the SwiftBLEBridge handle."""
    return _ble_bridge_handle


def set_ble_callback(slot: str, callable_: Any) -> None:
    """Register a Python callable as the handler for a BLE event slot. Used
    by IOSBLEDriver during `_setup_callbacks` after BLEInterface assigns its
    own callbacks to the driver. Pass `None` to clear."""
    if callable_ is None:
        _ble_callbacks.pop(slot, None)
    else:
        _ble_callbacks[slot] = callable_


def _ble_get_callback(slot: str) -> Any:
    """Swift-called lookup. Returns the stored callable for `slot`, or None.
    PythonBridge.invokeBLECallback uses this to fetch the PyObject*  ref then
    calls it via `PyObject_CallObject`."""
    return _ble_callbacks.get(slot)


def clear_ble_callbacks() -> None:
    """Drop every registered BLE callback. Called from `stop()` / restart so
    we don't keep references to closures bound to a torn-down driver."""
    _ble_callbacks.clear()


# Smoke-test entry point: register a callable that doubles its arg. The
# Swift side calls `invokeBLECallbackBoolSync(slot="_test_roundtrip", args=[5])`
# and asserts the bool return is True. Used by `lxma-test://test-ble-callback-roundtrip`
# to validate the Phase 2 wiring without needing a real BLE peer.
def _install_test_roundtrip_callback() -> None:
    """Register a `_test_roundtrip` slot that returns True iff the int arg is even."""
    def _cb(value: int) -> bool:
        return int(value) % 2 == 0
    set_ble_callback("_test_roundtrip", _cb)


def diagnose_ios_ble_interface() -> str:
    """Smoke-test the same exec() path RNS uses for external interfaces.
    Reads `<configDir>/interfaces/IOSBLEInterface.py`, exec()s it in a
    fresh namespace mirroring RNS.Reticulum:1011-1017, returns the
    formatted exception (or "ok") so Swift can write it to DiagLog.

    Used to surface IOSBLEInterface import errors that RNS swallows
    when `panic_on_interface_error = no` is set."""
    import os
    import traceback as _tb
    with _lock:
        config_dir = _state.get("config_dir") or ""
    if not config_dir:
        return "no config_dir set"
    path = os.path.join(config_dir, "interfaces", "IOSBLEInterface.py")
    if not os.path.isfile(path):
        return f"file missing: {path}"
    interface_globals = {}
    try:
        import RNS as _RNS
        interface_globals["Interface"] = _RNS.Interfaces.Interface.Interface
        interface_globals["RNS"] = _RNS
        # Important: set __file__ so the file's `_this_file` discovery works.
        interface_globals["__file__"] = path
        with open(path) as f:
            code = f.read()
        exec(code, interface_globals)
        cls = interface_globals.get("interface_class")
        if cls is None:
            return "exec ok but interface_class is None"
    except BaseException as e:
        return "EXC at exec: " + _tb.format_exc()
    # Try to instantiate exactly as RNS does: pass Transport + a minimal
    # interface_config dict mirroring what Reticulum would build from
    # the [[ble0]] section.
    try:
        config_section = {
            "name": "ble-diagnose",
            "type": "IOSBLEInterface",
            "interface_enabled": True,
            "enabled": True,
            "mode": "full",
            "ble_power_preset": "balanced",
        }
        instance = cls(_RNS.Transport, config_section)
        return f"instantiate ok class={cls.__name__} repr={instance!r}"
    except BaseException as e:
        return "EXC at instantiate: " + _tb.format_exc()
