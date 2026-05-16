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


class _LXMFAnnounceHandler:
    """Aspect-filtered to lxmf.delivery; everything else Reticulum routes elsewhere."""

    aspect_filter = "lxmf.delivery"
    receive_path_responses = True

    def received_announce(
        self,
        destination_hash: bytes,
        announced_identity: "RNS.Identity",
        app_data: bytes | None,
    ) -> None:
        display_name = _decode_announce_app_data(app_data)
        _put(
            "announce",
            dest_hash=destination_hash.hex(),
            display_name=display_name,
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

        handler = _LXMFAnnounceHandler()
        RNS.Transport.register_announce_handler(handler)
        _state["handler"] = handler

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


def stop() -> None:
    with _lock:
        if not _state["started"]:
            return
        try:
            if _state["handler"] is not None:
                RNS.Transport.deregister_announce_handler(_state["handler"])
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

        _state.update({
            "started": False,
            "reticulum": None,
            "router": None,
            "identity": None,
            "destination": None,
            "handler": None,
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
