"""rns_bridge — Python-side glue for Columba iOS PoC.

The Swift `PythonBridge` calls these module-level functions over the C-API
(via PyImport_ImportModule + PyObject_CallObject). Callbacks from Reticulum and
LXMF run on the RNS worker threads; rather than wire C-callable function pointers
across the Swift/Python boundary, we drop events onto a thread-safe queue that
Swift drains on a timer. Single-threaded simple, no GIL juggling for callbacks.

Scope: TCPClientInterface only, opportunistic LXMF only. Announces are tracked
for all aspects in `_TRACKED_ASPECTS` (lxmf.delivery, lxmf.propagation,
lxst.telephony, nomadnetwork.node) via one per-aspect RNS announce handler each
— do NOT narrow this to lxmf.delivery: Swift relies on the emitted aspect as the
sole signal for typing peers vs relays vs audio vs sites.
"""

from __future__ import annotations

import copy
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

# Patch platform.system() to return "Darwin" on iOS before RNS imports.
#
# RNS.Interfaces.util.netinfo branches on `platform.system() == "Darwin" or
# "BSD" in platform.system()` to pick the right sockaddr ctypes struct
# layout. iOS' Python returns `platform.system() == "iOS"`, so netinfo
# falls through to the Linux layout (sa_family at offset 0, 2 bytes wide)
# and misreads every address. iOS is Darwin under the hood (sa_len at
# byte 0, sa_family at byte 1, confirmed via raw getifaddrs probe), so
# the Darwin path is the correct one — we just have to make netinfo
# take it. No upstream RNS code branches on "iOS" specifically, so
# nothing else cares about this rename.
import platform as _platform
_real_system = _platform.system
_platform.system = lambda *a, **kw: "Darwin" if _real_system(*a, **kw) == "iOS" else _real_system(*a, **kw)

import RNS
import LXMF


# ── Native multi-threaded stamp PoW (iOS) ──────────────────────────────────
# iOS's embedded CPython ships no `_multiprocessing`, so upstream LXMF's
# `LXStamper.job_linux` throws `ModuleNotFoundError: _multiprocessing` and no
# stamp is ever produced — messages to peers that require a stamp cost (e.g.
# Sideband) never deliver. (iOS reports `sys.platform == "ios"`, which misses
# LXStamper's macOS `job_simple` branch.) We offload the proof-of-work to a
# native, multi-threaded Swift implementation reached via ctypes — the iOS
# analog of Columba Android's `event_bridge.install_external_stamp_generator`
# + Kotlin `StampGenerator`. The `columba_stamp_job_*` @_cdecl shims live in
# SwiftBLEBridge and are statically linked so `CDLL(None)` can resolve them.
import ctypes

try:
    _columba_lib = ctypes.CDLL(None)
except OSError:
    _columba_lib = None


def _bind_stamp_fn(symbol: str, argtypes: list[Any], restype: Any = ctypes.c_int32):
    if _columba_lib is None:
        return None
    try:
        fn = getattr(_columba_lib, symbol)
    except AttributeError:
        return None
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


# Native stamp jobs keep executable work and cancellation state in Swift. Python
# only calls signed C-ABI functions. In particular, never pass a ctypes callback
# into native code: executable callback trampolines can violate hardened iOS
# code-signing policy and terminate the process with an invalid-page error.
_stamp_job_start_fn = _bind_stamp_fn(
    "columba_stamp_job_start",
    [ctypes.c_char_p, ctypes.c_int32, ctypes.c_int32],
    ctypes.c_uint64,
)
_stamp_job_poll_fn = _bind_stamp_fn(
    "columba_stamp_job_poll",
    [ctypes.c_uint64, ctypes.c_char_p],
)
_stamp_job_cancel_fn = _bind_stamp_fn(
    "columba_stamp_job_cancel",
    [ctypes.c_uint64],
)
_stamp_job_release_fn = _bind_stamp_fn(
    "columba_stamp_job_release",
    [ctypes.c_uint64],
)
_stamp_jobs_cancel_all_fn = _bind_stamp_fn(
    "columba_stamp_jobs_cancel_all",
    [],
)


def _native_stamp_jobs_available() -> bool:
    return all(
        fn is not None
        for fn in (
            _stamp_job_start_fn,
            _stamp_job_poll_fn,
            _stamp_job_cancel_fn,
            _stamp_job_release_fn,
            _stamp_jobs_cancel_all_fn,
        )
    )


def _token_is_cancelled(cancellation_token: Any) -> bool:
    """Treat an invalid or expired foreign token as cancellation."""
    try:
        return bool(cancellation_token.is_cancelled())
    except Exception:
        return True


def _native_stamp_pow(workblock: bytes, stamp_cost: int, cancellation_token: Any):
    """Run native multi-threaded PoW with job-owned native cancellation."""
    if not _native_stamp_jobs_available():
        return None

    start_job = _stamp_job_start_fn
    poll_job = _stamp_job_poll_fn
    cancel_job = _stamp_job_cancel_fn
    release_job = _stamp_job_release_fn
    assert start_job is not None
    assert poll_job is not None
    assert cancel_job is not None
    assert release_job is not None

    payload = bytes(workblock)
    job_id = int(start_job(payload, len(payload), int(stamp_cost)))
    if job_id == 0:
        return None

    out = ctypes.create_string_buffer(32)
    try:
        while True:
            if _token_is_cancelled(cancellation_token):
                cancel_job(job_id)

            status = int(poll_job(job_id, out))
            if status == 32:
                # Close the race where cancellation arrives after the pre-poll
                # check but before Python observes a completed native proof.
                if _token_is_cancelled(cancellation_token):
                    cancel_job(job_id)
                    return None
                return out.raw[:32]
            if status < 0:
                return None
            if status != 0:
                RNS.log(
                    f"native stamp gen: unexpected poll status {status}",
                    RNS.LOG_WARNING,
                )
                return None
            time.sleep(0.01)
    finally:
        release_job(job_id)


def _install_native_stamp_generator() -> None:
    """Register the native (Swift, multi-threaded) PoW as LXMF's external stamp
    generator. The torlando-tech LXMF fork's `LXStamper.set_external_generator`
    hook makes `generate_stamp` delegate its proof-of-work to us — necessary on
    iOS, whose embedded CPython has no `_multiprocessing` (stock `job_linux`
    raises `ModuleNotFoundError`). LXMF still does its own workblock derivation +
    value calc, so the stamp is byte-identical to what the receiver validates.
    iOS analog of Android's `event_bridge.install_external_stamp_generator`.
    No-ops (warning) if the native symbol or the fork hook is absent."""
    try:
        LXStamper = LXMF.LXStamper
    except Exception as e:  # noqa: BLE001
        RNS.log(f"native stamp gen: LXStamper unavailable: {e}", RNS.LOG_DEBUG)
        return
    if not _native_stamp_jobs_available():
        RNS.log(
            "native stamp gen: native job symbols not found; stamp generation "
            "will fail on iOS",
            RNS.LOG_WARNING,
        )
        return
    if not hasattr(LXStamper, "set_external_generator"):
        RNS.log(
            "native stamp gen: LXStamper has no set_external_generator — this is "
            "stock LXMF, not the torlando fork; stamps will fail on iOS",
            RNS.LOG_WARNING,
        )
        return

    def _external_generator(workblock, stamp_cost, cancellation_token):
        # LXStamper contract: (workblock, cost, token) -> (stamp, rounds).
        _t0 = time.time()
        stamp = _native_stamp_pow(
            bytes(workblock), int(stamp_cost), cancellation_token
        )
        RNS.log(
            f"native stamp: cost={stamp_cost} in {round((time.time()-_t0)*1000)}ms"
            + ("" if stamp is not None else " (cancelled or no stamp)"),
            RNS.LOG_INFO,
        )
        return (stamp, 0) if stamp is not None else (None, 0)

    try:
        LXStamper.set_external_generator(
            _external_generator, pass_cancellation_token=True
        )
    except Exception as e:  # noqa: BLE001
        RNS.log(f"native stamp gen: registration failed: {e}", RNS.LOG_WARNING)
        return
    RNS.log("native cancellable stamp generator registered", RNS.LOG_INFO)


def _uninstall_native_stamp_generator() -> None:
    """Clear LXMF's process-global callback and cooperatively cancel its jobs."""
    try:
        if _stamp_jobs_cancel_all_fn is not None:
            _stamp_jobs_cancel_all_fn()
    except Exception as e:  # noqa: BLE001
        RNS.log(f"native stamp gen: cancel-all failed: {e}", RNS.LOG_DEBUG)

    # Always attempt process-global callback removal, even when native cleanup
    # fails. Retaining it can reference stale embedded-runtime state.
    try:
        LXStamper = LXMF.LXStamper
        setter = getattr(LXStamper, "set_external_generator", None)
        if setter is not None:
            setter(None)
    except Exception as e:  # noqa: BLE001
        # Teardown is best-effort and must never prevent the remaining bridge
        # state from being released.
        RNS.log(f"native stamp gen: unregister failed: {e}", RNS.LOG_DEBUG)


def _install_native_stamp_generator_unless_stopping() -> bool:
    """Install only while this startup still owns the runtime lifecycle."""
    if _runtime_teardown_requested.is_set():
        return False
    _install_native_stamp_generator()
    # Teardown may have begun during registration while waiting for `_lock`.
    if _runtime_teardown_requested.is_set():
        _uninstall_native_stamp_generator()
        return False
    return True


_lock = threading.Lock()
_propagation_sync_cancellation_lock = threading.Condition()
_active_propagation_sync_cancellation: threading.Event | None = None
# Teardown publishes intent without waiting for `_lock`, allowing a start that
# already owns it to reject or undo process-global callback registration.
_runtime_teardown_requested = threading.Event()
_runtime_teardown_lock = threading.Lock()
_runtime_teardown_count = 0


def _begin_runtime_teardown() -> None:
    global _runtime_teardown_count
    with _runtime_teardown_lock:
        _runtime_teardown_count += 1
        _runtime_teardown_requested.set()


def _end_runtime_teardown() -> None:
    global _runtime_teardown_count
    with _runtime_teardown_lock:
        _runtime_teardown_count = max(0, _runtime_teardown_count - 1)
        if _runtime_teardown_count == 0:
            _runtime_teardown_requested.clear()


def _balanced_runtime_teardown(function):
    """Balance teardown publication even if cleanup raises unexpectedly."""
    def wrapped(*args, **kwargs):
        _begin_runtime_teardown()
        try:
            return function(*args, **kwargs)
        finally:
            _end_runtime_teardown()
    return wrapped
# Bumped on every start()/stop()/reset_identity() so the post-start delayed
# re-announce daemon thread can detect it has been superseded (by a teardown
# or a restart) and bail before announcing a dead / previous-session
# destination.
_announce_generation = 0
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
        # Surface every handler invocation so we can tell aspect-filter
        # mismatches apart from "handler never ran". Goes to stdout which
        # rns_bridge redirects to NSLog; AppServices picks it up as
        # [py-stdout] lines.
        try:
            print(f"[announce-handler] aspect={self._aspect} dest={destination_hash.hex()[:16]}", flush=True)
        except Exception:
            pass
        # Pass the raw announce app_data straight up; Swift decodes the
        # display name (aspect-specific layout knowledge lives there, in
        # AppDataParser / PropagationNodeInfo, not in this thin bridge).
        app_data_hex = app_data.hex() if app_data else ""
        public_keys_hex = ""
        try:
            pub = getattr(announced_identity, "get_public_key", None)
            if callable(pub):
                public_keys_hex = pub().hex()
        except Exception:
            pass
        # Look up the receiving interface and hop count for this announce.
        # RNS stores both on the path_table entry immediately after the
        # announce is processed (Transport.py:1999):
        #   entry = [now, received_from, announce_hops, expires,
        #            random_blobs, receiving_interface, packet_hash]
        # So index 2 is `announce_hops` (number of network hops the
        # announce traversed; 0 = direct neighbor, 1+ = transit through
        # transport nodes). Index 5 is the receiving Interface object.
        interface_name = ""
        hops = 0
        try:
            entry = RNS.Transport.path_table.get(destination_hash)
            if entry:
                if len(entry) > 5 and entry[5] is not None:
                    interface_name = getattr(entry[5], "name", None) or str(entry[5])
                if len(entry) > 2 and entry[2] is not None:
                    hops = int(entry[2])
        except Exception:
            pass
        _put(
            "announce",
            dest_hash=destination_hash.hex(),
            app_data=app_data_hex,
            aspect=self._aspect,
            public_keys=public_keys_hex,
            interface_name=interface_name,
            hops=hops,
        )


# Aspects the Columba UI surfaces. Order matters: when the same destination
# announces under multiple aspects we'll emit one event per aspect.
_TRACKED_ASPECTS = (
    "lxmf.delivery",
    "lxmf.propagation",
    "nomadnetwork.node",
    "lxst.telephony",
)


def _canonical_inbound_hash(message: Any) -> bytes | None:
    """Return the wire LXMF hash, recovering it from the packed LXM if needed."""
    canonical = getattr(message, "hash", None) or getattr(message, "message_id", None)
    if canonical:
        return bytes(canonical)

    # LXMF sets both hash fields in unpack_from_bytes() before routing a valid
    # inbound message. Keep this fallback for alternate router versions that
    # retain the original packed LXM but do not expose one of those aliases.
    packed = getattr(message, "packed", None)
    if packed:
        try:
            recovered = LXMF.LXMessage.unpack_from_bytes(bytes(packed))
            recovered_hash = getattr(recovered, "hash", None)
            if recovered_hash:
                return bytes(recovered_hash)
        except Exception:
            pass
    return None


def _inbound_delivery_method_name(message: Any) -> str:
    """Map the received LXMF method to the shared persistence vocabulary."""
    method = getattr(message, "method", None)
    for attribute, name in (
        ("OPPORTUNISTIC", "opportunistic"),
        ("DIRECT", "direct"),
        ("PROPAGATED", "propagated"),
        ("PAPER", "paper"),
    ):
        if method == getattr(LXMF.LXMessage, attribute, None):
            return name
    return ""


def _receiving_interface(message: Any) -> Any | None:
    """Resolve the `RNS.Interface` a message arrived on, best-effort.

    Two sources in priority order (mirrors Columba Android's event_bridge):
      1. The torlando-tech LXMF fork sets `message.receiving_interface` on
         inbound opportunistic messages. Upstream LXMF leaves it off entirely,
         so getattr-guard.
      2. Fallback to `RNS.Transport.path_table[source_hash][5]` for
         link-based (DIRECT) deliveries and any case where the LXMF annotation
         didn't fire — every reachable destination has a path_table entry
         whose index 5 is the receiving Interface object.

    Returns `None` when neither source yields an interface; the caller treats
    that as "no signal metrics available" and omits them from the event.
    """
    recv_iface = getattr(message, "receiving_interface", None)
    if recv_iface is not None:
        return recv_iface
    source_hash_bytes = getattr(message, "source_hash", None)
    if source_hash_bytes is None:
        return None
    try:
        path_entry = RNS.Transport.path_table.get(source_hash_bytes)
        if path_entry is not None and len(path_entry) > 5:
            return path_entry[5]
    except Exception as e:  # noqa: BLE001 — fallback is best-effort
        RNS.log(f"rns_bridge: path_table fallback failed: {e}", RNS.LOG_DEBUG)
    return None


def _signal_metrics(interface_obj: Any) -> tuple[int | None, float | None]:
    """Extract (rssi, snr) from a receiving `RNS.Interface` at delivery time.

    Mirrors Columba Android's event_bridge `_signal_metrics` plus the legacy
    `signal_quality.extract_signal_metrics` BLE peer-interface fallback:
    RNode-class interfaces expose `get_rssi()` + `get_snr()`; TCP / Auto /
    Backbone interfaces don't, so the result is `(None, None)` for those. BLE
    peer sub-interfaces (`ble_reticulum.BLEPeerInterface`) don't expose
    `get_rssi` themselves but carry a `parent_interface` that does, so we try
    the object itself and then its parent. BLE has no SNR on any platform.

    Best-effort: any attribute-access / call exception falls back to `None`,
    because a signal-metrics failure must never wedge inbound message delivery.
    The values are interface-wide "latest received" stats captured at delivery
    time, not per-packet (same semantics as Android).
    """
    rssi = None
    snr = None
    if interface_obj is None:
        return rssi, snr
    candidates = [interface_obj]
    parent = getattr(interface_obj, "parent_interface", None)
    if parent is not None:
        candidates.append(parent)
    for candidate in candidates:
        if rssi is None:
            get_rssi = getattr(candidate, "get_rssi", None)
            if callable(get_rssi):
                try:
                    v = get_rssi()
                    if v is not None:
                        rssi = int(v)
                except Exception as e:  # noqa: BLE001
                    RNS.log(f"rns_bridge: get_rssi failed: {e}", RNS.LOG_DEBUG)
        if snr is None:
            get_snr = getattr(candidate, "get_snr", None)
            if callable(get_snr):
                try:
                    v = get_snr()
                    if v is not None:
                        snr = float(v)
                except Exception as e:  # noqa: BLE001
                    RNS.log(f"rns_bridge: get_snr failed: {e}", RNS.LOG_DEBUG)
        if rssi is not None and snr is not None:
            break
    return rssi, snr


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
    # Carry the inbound LXMF field map (telemetry / attachments / reactions /
    # replies / icon / cease) to Swift as MessagePack-packed hex. Swift decodes
    # it via LxmfFieldCodec → IncomingMessageHandler. Empty when there are no
    # fields or packing fails (graceful — content/title still flow).
    fields_hex = ""
    try:
        if getattr(message, "fields", None):
            from RNS.vendor import umsgpack
            fields_hex = umsgpack.packb(message.fields).hex()
    except Exception:
        fields_hex = ""
    src = message.source_hash.hex() if message.source_hash else ""
    # Preserve the canonical LXMF hash. Reactions identify their target by this
    # exact hash; synthesising a different app-local id makes peers receive the
    # reaction frame but fail to find the target message.
    canonical_hash = _canonical_inbound_hash(message)
    if canonical_hash is None:
        # Preserve the delivered content and fields even when an alternate or
        # malformed LXMF producer omitted the canonical wire hash. Swift assigns
        # a namespaced local persistence ID and keeps it out of reaction/reply
        # targeting; dropping the callback here would lose the whole message.
        RNS.log("Inbound LXMF message has no recoverable wire hash", RNS.LOG_ERROR)
    message_hash = canonical_hash.hex() if canonical_hash is not None else ""
    # Signal metrics for the receiving interface (RNode: RSSI + SNR; BLE: RSSI
    # only, and only for the central role that has an RSSI to report; TCP /
    # Auto / propagated: none). Best-effort — a failure here must not lose the
    # message, so both fall back to None when the interface is unknown or the
    # metric is unavailable. Mirrors Columba Android's event_bridge delivery
    # payload. `receiving_interface`/`receiving_hops` resolution lives in
    # `_receiving_interface`; the metric extraction lives in `_signal_metrics`.
    rssi, snr = _signal_metrics(_receiving_interface(message))
    _put(
        "inbound",
        source_hash=src,
        message_hash=message_hash,
        content=content,
        title=title,
        fields_hex=fields_hex,
        method=_inbound_delivery_method_name(message),
        rssi=rssi,
        snr=snr,
    )


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
    # Registration is process-global. Clear stale callbacks/jobs outside the
    # bridge lock so LXMF cancellation cannot deadlock against bridge teardown.
    with _lock:
        if _state["started"]:
            return _local_info()
    _uninstall_native_stamp_generator()

    with _lock:
        # A concurrent start may have completed while cancellation ran.
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
        # NOTE: no wildcard (aspect_filter=None) handler. One used to be
        # registered here as a diagnostic, but it surfaced every announce the
        # node heard — including aspects Columba doesn't display — as phantom
        # "*"/Peer cards (e.g. a propagation announce whose bool-first app_data
        # rendered as the display name "False"), and could clobber a
        # correctly-typed announce since path entries are keyed by destination
        # hash (last write wins). Only the four tracked aspects above feed the
        # network list now.
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

        global _announce_generation
        _announce_generation += 1
        _reannounce_gen = _announce_generation

        def _delayed_reannounce() -> None:
            for delay in (2, 5, 15, 30):
                time.sleep(delay)
                # stop()/reset_identity()/a restart bumps the generation; bail
                # so we never re-announce a torn-down destination — or the
                # previous session's destination after a stop->start restart.
                if _announce_generation != _reannounce_gen:
                    return
                try:
                    delivery_destination.announce()
                except Exception:
                    pass

        threading.Thread(target=_delayed_reannounce, daemon=True).start()

        # Install only after startup has fully assembled all state, so an
        # exception during partial startup cannot retain a global callback.
        _install_native_stamp_generator_unless_stopping()
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


def set_incoming_message_size_limit_kb(limit_kb: int) -> dict[str, Any]:
    """Set LXMRouter.delivery_per_transfer_limit in KB.

    This single router property drives both the delivery_resource_advertised
    transfer limit and the propagation WANT transfer limit. It must be applied
    on a running router; callers should treat not-started/no-router as errors.
    """
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        router = _state["router"]
        if router is None:
            return {"ok": False, "reason": "no-router"}
        bounded = max(512, min(int(limit_kb), 131072))
        try:
            router.delivery_per_transfer_limit = bounded
        except Exception as e:
            return {"ok": False, "reason": f"set-failed: {e}"}
        return {"ok": True, "reason": "ok", "limit_kb": bounded}


def _cancel_router_propagation_request(router: Any) -> bool:
    """Synchronously tear down one router-owned propagation request."""
    if router is None:
        return False
    cancel = getattr(router, "cancel_propagation_node_requests", None)
    if not callable(cancel):
        return False
    try:
        cancel()
        return True
    except Exception:
        return False


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
    cancellation = threading.Event()
    global _active_propagation_sync_cancellation
    with _propagation_sync_cancellation_lock:
        while (
            _active_propagation_sync_cancellation is not None
            and _active_propagation_sync_cancellation.is_set()
        ):
            _propagation_sync_cancellation_lock.wait()
        if _active_propagation_sync_cancellation is not None:
            return {"ok": False, "state": "transfer-failed", "received_messages": 0, "reason": "sync-in-progress"}
        _active_propagation_sync_cancellation = cancellation

    try:
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
        terminal_reached = False
        terminal_states = {
            getattr(LXMF.LXMRouter, "PR_COMPLETE", 0x07),
            getattr(LXMF.LXMRouter, "PR_NO_PATH", 0xF0),
            getattr(LXMF.LXMRouter, "PR_LINK_FAILED", 0xF1),
            getattr(LXMF.LXMRouter, "PR_TRANSFER_FAILED", 0xF2),
            getattr(LXMF.LXMRouter, "PR_NO_IDENTITY_RCVD", 0xF3),
            getattr(LXMF.LXMRouter, "PR_NO_ACCESS", 0xF4),
            getattr(LXMF.LXMRouter, "PR_FAILED", 0xFE),
        }
        while time.monotonic() < deadline:
            if cancellation.is_set():
                return {"ok": False, "state": "cancelled", "received_messages": 0, "reason": "cancelled"}
            try:
                state_val = getattr(router, "propagation_transfer_state", None)
                last_seen_state = state_val
                if state_val in terminal_states:
                    terminal_reached = True
                    break
            except Exception:
                pass
            time.sleep(0.5)

        if not terminal_reached:
            cancellation.set()
            _cancel_router_propagation_request(router)
            return {
                "ok": False,
                "state": "transfer_failed",
                "received_messages": 0,
                "reason": "timeout",
            }

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
    finally:
        with _propagation_sync_cancellation_lock:
            if _active_propagation_sync_cancellation is cancellation:
                _active_propagation_sync_cancellation = None
                _propagation_sync_cancellation_lock.notify_all()


def cancel_propagation_sync() -> dict[str, Any]:
    """Cancel an active bounded propagation-node request and its polling loop."""
    with _propagation_sync_cancellation_lock:
        cancellation = _active_propagation_sync_cancellation
        if cancellation is None:
            return {"ok": True, "active": False, "router_cancelled": False}
        cancellation.set()
        # Keep the operation slot occupied until the router-wide cancellation has
        # finished. Otherwise a successor can publish its fresh event and start a
        # request while this call is still about to tear down router propagation.
        with _lock:
            router = _state.get("router")
        cancelled_router = _cancel_router_propagation_request(router)
        return {"ok": True, "active": True, "router_cancelled": cancelled_router}


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
        getattr(LXMF.LXMRouter, "PR_LINK_FAILED", -10): "link_failed",
        getattr(LXMF.LXMRouter, "PR_TRANSFER_FAILED", -11): "transfer_failed",
        getattr(LXMF.LXMRouter, "PR_NO_IDENTITY_RCVD", -12): "no_identity_received",
        getattr(LXMF.LXMRouter, "PR_NO_ACCESS", -13): "no_access",
        getattr(LXMF.LXMRouter, "PR_FAILED", -14): "failed",
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
# Dedicated lock for the counter, NOT the shared `_lock`: _alloc_link_id is
# called from both the bridge thread (outbound links) and RNS callback threads
# (inbound link-established), and some callers already hold `_lock`, so reusing
# it here would deadlock (threading.Lock is non-reentrant).
_link_id_lock = threading.Lock()
_telephony_destination: Any = None  # RNS.Destination for lxst.telephony aspect


def _alloc_link_id() -> int:
    global _next_link_id_counter
    # `+= 1` is a read-modify-write — without a lock two threads can read the
    # same value and hand out duplicate ids that overwrite live _links entries.
    with _link_id_lock:
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


def open_link(
    dest_hash_hex: str,
    aspect: str = "lxst.telephony",
    identity_public_key_hex: str = "",
) -> dict[str, Any]:
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

    # Split the dotted aspect before resolving identity so a supplied public key
    # can be verified against the exact destination the caller requested.
    parts = aspect.split(".") if aspect else ["lxst", "telephony"]
    app_name = parts[0]
    aspects = parts[1:] if len(parts) > 1 else []

    peer_identity = RNS.Identity.recall(dest_hash)
    if peer_identity is None and identity_public_key_hex:
        try:
            supplied_public_key = bytes.fromhex(identity_public_key_hex)
            candidate = RNS.Identity(create_keys=False)
            candidate.load_public_key(supplied_public_key)
            candidate_dest = RNS.Destination(
                candidate,
                RNS.Destination.OUT,
                RNS.Destination.SINGLE,
                app_name,
                *aspects,
            )
            if candidate_dest.hash != dest_hash:
                return {"ok": False, "link_id": 0, "reason": "identity-mismatch"}
            peer_identity = candidate
        except Exception:
            return {"ok": False, "link_id": 0, "reason": "bad-identity"}
    # Identity and routing are separate concerns: a supplied public key is enough
    # to construct and verify the destination, but it does not prove that a
    # current path exists. Always perform a bounded path request before reporting
    # the telephone unreachable.
    try:
        has_path = bool(RNS.Transport.has_path(dest_hash))
    except Exception:
        has_path = False
    if not has_path:
        try:
            RNS.Transport.request_path(dest_hash)
        except Exception:
            pass
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            try:
                if RNS.Transport.has_path(dest_hash):
                    has_path = True
                    break
            except Exception:
                pass
            time.sleep(0.1)
    if not has_path:
        return {"ok": False, "link_id": 0, "reason": "no-path"}
    if peer_identity is None:
        peer_identity = RNS.Identity.recall(dest_hash)
    if peer_identity is None:
        return {"ok": False, "link_id": 0, "reason": "no-identity"}

    peer_dest = RNS.Destination(
        peer_identity, RNS.Destination.OUT, RNS.Destination.SINGLE,
        app_name, *aspects
    )
    try:
        link = RNS.Link(peer_dest)
    except Exception as e:
        return {"ok": False, "link_id": 0, "reason": f"link-init-failed: {e}"}

    link_id = _alloc_link_id()
    # Register the link in _links BEFORE wiring callbacks: _on_closed pops
    # _links[link_id], so if the link closes fast (route rejection / quick
    # timeout) before the entry exists, the pop misses and we'd later insert a
    # permanently-zombie entry. Same ordering the inbound path uses.
    with _lock:
        _links[link_id] = link
    _wire_link_callbacks(link, link_id)
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

    Updates the delivery destination's display name and lets LXMF build the
    announce app_data via its own `get_announce_app_data` (installed as the
    destination's default-app-data callback), then calls
    `delivery_destination.announce()` — the canonical LXMF delivery announce,
    identical to what `LXMRouter.announce()` emits. Queues the announce packet
    for every online interface.

    Returns `{ok: bool, reason: str}`. `not-started` when Python hasn't
    booted yet, `no-destination` when register_delivery_identity failed
    earlier in start(), `ok` on success."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        destination = _state["destination"]
        router = _state["router"]
        if destination is None or router is None:
            return {"ok": False, "reason": "no-destination"}

        # Announce via LXMF's own delivery-destination machinery instead of
        # hand-rolling app_data. Update the display name, (re)install LXMF's
        # get_announce_app_data as the destination's default app_data, then call
        # delivery_destination.announce(): RNS invokes the callable to build the
        # canonical msgpack [display_name, stamp_cost] — the exact format
        # Sideband and Android Columba emit — and the SAME app_data is reused for
        # any RNS path-request re-announce. (We previously froze app_data to
        # static [name, 0] bytes here, diverging from the real LXMF format.)
        try:
            if display_name:
                destination.display_name = display_name

            def _get_app_data() -> bytes:
                return router.get_announce_app_data(destination.hash)
            destination.set_default_app_data(_get_app_data)

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


def _clear_transport_class_state() -> None:
    """Drain the RNS.Transport class-level state that exit_handler() leaves
    behind. RNS.Transport is a process-global: its destinations / interfaces /
    path tables / announce handlers / identities persist across a Reticulum
    exit_handler(), so a follow-on start() would raise "Attempt to register an
    already registered destination" (Transport.register_destination) and reuse
    stale interfaces/paths. BOTH stop() and reset_identity() must call this
    before the next start() — keeping it in one place stops the two paths from
    drifting (reset_identity previously omitted it and broke identity switch)."""
    for _attr, _empty in (
        ("destinations", []),
        ("interfaces", []),
        ("path_table", {}),
        ("destination_table", {}),
        ("announce_handlers", []),
        ("identities", {}),
    ):
        try:
            setattr(RNS.Transport, _attr, _empty)
        except Exception:
            pass
    # exit_handler() sets RNS.loglevel = LOG_NONE; restore it so the next init's
    # RNS.log() calls are visible again.
    try:
        RNS.loglevel = RNS.LOG_VERBOSE
    except Exception:
        pass


@_balanced_runtime_teardown
def stop() -> None:
    # LXMF owns a process-global callback and may synchronously notify/cancel
    # jobs while clearing it. Never hold the bridge lock across that operation.
    _uninstall_native_stamp_generator()
    with _lock:
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

        # Drain the Transport class-level state exit_handler() leaves behind so
        # the next start() sees a clean slate (shared with reset_identity).
        _clear_transport_class_state()

        # Tear down any open RNS.Links and forget the telephony
        # destination so a subsequent start() doesn't trip on stale
        # callbacks pointing at a freed RNS.Transport.
        global _telephony_destination
        # Snapshot the links and clear the dict INSIDE the lock, then tear them
        # down OUTSIDE it (below). link.teardown() can fire _on_closed
        # synchronously once exit_handler() has stopped the transport threads,
        # and _on_closed does `with _lock: _links.pop(...)` — holding the
        # non-reentrant _lock across teardown() would deadlock the bridge.
        links_to_teardown = list(_links.values())
        _links.clear()
        _telephony_destination = None

        # Drop registered BLE callbacks so a subsequent start() doesn't
        # invoke closures bound to the previous driver / Swift bridge.
        clear_ble_callbacks()
        global _ble_bridge_handle, _announce_generation
        _ble_bridge_handle = None
        # Supersede any in-flight delayed re-announce thread (see start()).
        _announce_generation += 1

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

    # Outside the lock: tear down the snapshotted links so a synchronous
    # _on_closed (which re-acquires _lock) can't deadlock.
    for link in links_to_teardown:
        try:
            link.teardown()
        except Exception:
            pass


def add_interface(name: str) -> dict[str, Any]:
    """Hot-add a single interface to the *running* Reticulum stack — no restart.

    RNS attaches interfaces to a live `Transport` without re-initialising (it's
    exactly what the 1.x interface-discovery autoconnect path does — see
    `RNS.Discovery.InterfaceDiscovery.autoconnect` → `Reticulum._add_interface`).
    We reuse the higher-level `Reticulum._synthesize_interface()` — the same code
    path startup uses to bring up `[interfaces]` sections — so every interface
    type (TCP, Auto, RNode, and the external iOS BLE module) is handled by RNS's
    own logic rather than reimplemented here.

    `name` is the ConfigObj section name (PythonConfigWriter's sanitized
    "<display>-<id6>" form); it becomes the interface's `iface.name`, which is
    how `status()` and the Swift status poll match interfaces back to entities.

    The interface's `[[name]]` section is read *fresh from the on-disk config*
    rather than the running `reticulum.config`: Swift's PythonConfigWriter has
    already rewritten the full config file (for cold-launch durability) and the
    in-memory `reticulum.config` was parsed at init, so it won't contain a
    section added afterwards.

    Returns {"ok": bool, "reason": str}. Idempotent — re-adding a live
    interface returns ok=True / "already-present".
    """
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        reticulum = _state["reticulum"]
        config_dir = _state["config_dir"]
        if reticulum is None or config_dir is None:
            return {"ok": False, "reason": "no-reticulum"}

        for iface in list(RNS.Transport.interfaces):
            if getattr(iface, "name", None) == name:
                return {"ok": True, "reason": "already-present"}

        from RNS.vendor.configobj import ConfigObj
        config_path = os.path.join(config_dir, "config")
        try:
            cfg = ConfigObj(config_path)
        except Exception as e:
            return {"ok": False, "reason": f"config-read-failed: {e}"}

        if "interfaces" not in cfg or name not in cfg["interfaces"]:
            return {"ok": False, "reason": f"section-not-found: {name}"}
        section = cfg["interfaces"][name]

        # `_synthesize_interface` calls `RNS.panic()` (→ os._exit(255)) when an
        # interface fails to construct — at startup that aborts cleanly, but on
        # a *runtime* add a bad/unreachable config would take the whole app
        # down. Swap panic() for an exception for the duration so the failure
        # degrades to an error return. Also stub signal.signal: some interface
        # constructors (RNode) install handlers, which raises off the main
        # thread (we're on the Swift bridge queue). Both are safe because all
        # bridge entry points are serialized under `_lock`.
        import signal as _signal
        orig_panic = RNS.panic
        orig_signal = _signal.signal

        def _raise_panic():
            raise RuntimeError("interface synthesis panicked (bad config or unreachable endpoint)")

        RNS.panic = _raise_panic
        _signal.signal = lambda *_a, **_kw: None
        try:
            reticulum._synthesize_interface(section, name, instance_init=False)
        except Exception as e:
            RNS.trace_exception(e)
            return {"ok": False, "reason": f"synthesize-failed: {e}"}
        finally:
            RNS.panic = orig_panic
            _signal.signal = orig_signal

        # Keep the live in-memory config consistent with what's now attached,
        # so a later status()/stop() reasons over the same view.
        try:
            if "interfaces" not in reticulum.config:
                reticulum.config["interfaces"] = {}
            reticulum.config["interfaces"][name] = dict(section)
        except Exception:
            pass

        for iface in RNS.Transport.interfaces:
            if getattr(iface, "name", None) == name:
                RNS.log(f"Hot-added interface {name}", RNS.LOG_NOTICE)
                return {"ok": True, "reason": "added"}
        return {"ok": False, "reason": "not-attached"}


def remove_interface(name: str) -> dict[str, Any]:
    """Hot-remove an interface from the running Reticulum stack — no restart.

    Calls the interface's `detach()` then drops it from
    `RNS.Transport.interfaces`, along with any child interfaces that name it as
    their `parent_interface` (e.g. AutoInterface's dynamically-spawned
    AutoInterfacePeer rows).

    Teardown completeness depends on the interface type's `detach()`:
      • TCPClientInterface.detach() shuts down + closes the socket — clean.
      • AutoInterface.detach() upstream only sets `online = False`; it does NOT
        close the multicast discovery sockets or join their daemon threads, so
        the OS sockets stay bound until process exit. Re-adding the same
        AutoInterface before a cold launch can therefore collide on the
        multicast bind. (Tracked for an upstream RNS teardown fix; TCP/Backbone
        removal is unaffected.)

    Returns {"ok": bool, "reason": str}.
    """
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}

        removed = 0
        for iface in list(RNS.Transport.interfaces):
            is_target = getattr(iface, "name", None) == name
            parent = getattr(iface, "parent_interface", None)
            is_child = parent is not None and getattr(parent, "name", None) == name
            if not (is_target or is_child):
                continue
            try:
                iface.detach()
            except Exception as e:
                RNS.log(f"detach failed for {iface}: {e}", RNS.LOG_ERROR)
            try:
                RNS.Transport.interfaces.remove(iface)
                removed += 1
            except ValueError:
                pass

        try:
            reticulum = _state["reticulum"]
            if reticulum is not None and "interfaces" in reticulum.config \
                    and name in reticulum.config["interfaces"]:
                del reticulum.config["interfaces"][name]
        except Exception:
            pass

        if removed:
            RNS.log(f"Hot-removed interface {name} ({removed} entr{'y' if removed == 1 else 'ies'})", RNS.LOG_NOTICE)
        return {"ok": removed > 0, "reason": f"removed-{removed}" if removed else "not-found"}


def persist() -> dict[str, Any]:
    """Force RNS to flush its path table + known destinations to disk now.

    RNS only persists on a 12-hour timer (`Reticulum.PERSIST_INTERVAL`) or in
    `exit_handler` on a clean shutdown. iOS suspends/kills the app without a
    clean exit and long before 12h, so left to itself RNS almost never writes
    `<storage>/destination_table` or `known_destinations` — and a cold start
    then reloads nothing. Columba calls this when the app backgrounds so RNS's
    routing + recalled identities (and thus the ability to message previously
    heard peers) survive an app restart. Mirrors what RNS's own periodic
    `__persist_data` does, but unthrottled.
    """
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
        try:
            RNS.Transport.persist_data()
        except Exception as e:
            RNS.log(f"persist: Transport.persist_data failed: {e}", RNS.LOG_ERROR)
        try:
            RNS.Identity.persist_data()
        except Exception as e:
            RNS.log(f"persist: Identity.persist_data failed: {e}", RNS.LOG_ERROR)
        return {"ok": True, "reason": "persisted"}


def remember_peer_identity(dest_hash_hex: str, public_key_hex: str) -> dict[str, Any]:
    """Retain a QR-provided LXMF delivery identity without requesting a path."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
    try:
        dest_hash = bytes.fromhex(dest_hash_hex)
        public_key = bytes.fromhex(public_key_hex)
    except ValueError:
        return {"ok": False, "reason": "bad-identity"}
    if len(dest_hash) != 16 or len(public_key) != 64:
        return {"ok": False, "reason": "bad-identity"}
    try:
        candidate = RNS.Identity(create_keys=False)
        candidate.load_public_key(public_key)
        candidate_dest = RNS.Destination(
            candidate, RNS.Destination.OUT, RNS.Destination.SINGLE,
            "lxmf", "delivery",
        )
        if candidate_dest.hash != dest_hash:
            return {"ok": False, "reason": "identity-mismatch"}
        RNS.Identity.remember(None, dest_hash, public_key, None)
        persistence_result = RNS.Identity.persist_data()
        # Current RNS returns None on success. An explicit False from this
        # boundary means the identity was not durably retained.
        if persistence_result is False:
            return {"ok": False, "reason": "persist-failed"}
        return {"ok": True, "reason": "remembered"}
    except Exception as e:
        return {"ok": False, "reason": f"remember-failed: {e}"}


def resolve_path(dest_hash_hex: str, timeout_seconds: float = 10.0) -> dict[str, Any]:
    """Request a missing path once and wait boundedly for route + identity."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "reason": "not-started"}
    try:
        dest_hash = bytes.fromhex(dest_hash_hex)
    except ValueError:
        return {"ok": False, "reason": "bad-hash"}

    def resolved() -> bool:
        try:
            return bool(RNS.Transport.has_path(dest_hash)) and RNS.Identity.recall(dest_hash) is not None
        except Exception:
            return False

    if resolved():
        return {"ok": True, "reason": "known"}
    try:
        RNS.Transport.request_path(dest_hash)
    except Exception as e:
        return {"ok": False, "reason": f"request-failed: {e}"}

    deadline = time.monotonic() + max(0.0, float(timeout_seconds))
    while time.monotonic() < deadline:
        if resolved():
            return {"ok": True, "reason": "resolved"}
        time.sleep(0.1)
    return {"ok": False, "reason": "timeout"}


def send_opportunistic(dest_hash_hex: str, content: str, fields_hex: str = "",
                       method: str = "opportunistic",
                       failure_fallback_method: str = "") -> dict[str, Any]:
    """Send an LXMF message and optionally retry an async failure once.

    `method` selects the initial LXMF desired method. When
    `failure_fallback_method` is ``"propagated"``, a later asynchronous failure
    of the accepted opportunistic submission requeues the exact same LXMessage
    once through the configured propagation node. Reusing the object preserves
    its hash, timestamp and complete field map for Swift persistence.
    """
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
        fields = None
        if fields_hex:
            try:
                from RNS.vendor import umsgpack
                fields = umsgpack.unpackb(bytes.fromhex(fields_hex))
            except Exception:
                fields = None

        methods = {
            "opportunistic": LXMF.LXMessage.OPPORTUNISTIC,
            "direct": LXMF.LXMessage.DIRECT,
            "propagated": LXMF.LXMessage.PROPAGATED,
        }
        desired_method = methods.get(method, LXMF.LXMessage.OPPORTUNISTIC)
        fallback_method = methods.get(failure_fallback_method)

        # PROPAGATED requires an explicit relay. LXMRouter versions have varied
        # in whether they reject this synchronously, so enforce the public
        # bridge contract here instead of treating local queue admission as
        # evidence that a relay exists.
        if (
            desired_method == LXMF.LXMessage.PROPAGATED
            and getattr(router, "outbound_propagation_node", None) is None
        ):
            return {"ok": False, "reason": "no-propagation-node"}

        msg = LXMF.LXMessage(
            peer_dest,
            local_dest,
            content,
            title="",
            fields=fields,
            desired_method=desired_method,
        )

        callback_lock = threading.RLock()
        callback_state = {
            "outcome": None,
            "fallback_started": False,
            "retrying_emitted": False,
        }

        def _effective_method_name(m: "LXMF.LXMessage") -> str:
            method_value = getattr(m, "method", None)
            if method_value == LXMF.LXMessage.OPPORTUNISTIC:
                return "opportunistic"
            if method_value == LXMF.LXMessage.DIRECT:
                return "direct"
            if method_value == LXMF.LXMessage.PROPAGATED:
                return "propagated"
            return ""

        def _emit_lifecycle(m: "LXMF.LXMessage", state: str, reason: str) -> None:
            with callback_lock:
                current = callback_state["outcome"]
                if state == "retrying_propagated":
                    if current is not None or callback_state["retrying_emitted"]:
                        return
                    callback_state["retrying_emitted"] = True
                elif state == "sent":
                    if current is not None:
                        return
                elif state == "delivered":
                    if current == "delivered":
                        return
                elif state == "failed":
                    if current in ("delivered", "failed"):
                        return
                else:
                    return
                if state != "retrying_propagated":
                    callback_state["outcome"] = state
                try:
                    _put(
                        "delivery",
                        message_hash=m.hash.hex(),
                        state=state,
                        reason=reason,
                        method=_effective_method_name(m),
                    )
                except Exception:
                    pass

        def _on_delivered(m: "LXMF.LXMessage") -> None:
            # LXMF invokes the same callback for recipient proof (DELIVERED) and
            # propagation-node acceptance (SENT). Keep those semantics distinct.
            if m.state == LXMF.LXMessage.SENT:
                _emit_lifecycle(m, "sent", "propagation-accepted")
            elif m.state == LXMF.LXMessage.DELIVERED:
                _emit_lifecycle(m, "delivered", "recipient-proof")

        def _on_propagated_failed(m: "LXMF.LXMessage") -> None:
            _emit_lifecycle(m, "failed", "propagated-failed")

        def _enqueue_propagated(m: "LXMF.LXMessage") -> None:
            # LXMRouter.fail_message invokes callbacks while process_outbound
            # holds outbound_processing_lock in the shipping LXMF runtime. Run
            # requeue work after leaving that callback stack so handle_outbound
            # cannot wait on the lock owned by its own caller. Re-enter through
            # the bridge lock as an ordinary send would, and fail closed if a
            # stop/reset replaced this worker's captured router.
            original_hash = m.hash
            try:
                # Build and validate propagated transport representation on a
                # shallow copy. Recipient proof can still win while this work is
                # in flight, and the authoritative primary message stays wholly
                # opportunistic until final enqueue admission.
                prepared = copy.copy(m)
                prepared.desired_method = LXMF.LXMessage.PROPAGATED
                prepared.packed = None
                prepared.pack()
                if (
                    original_hash is None
                    or prepared.hash != original_hash
                    or prepared.propagation_packed is None
                ):
                    raise ValueError("propagation repack changed canonical message")

                with _lock:
                    if (
                        _runtime_teardown_requested.is_set()
                        or not _state["started"]
                        or _state["router"] is not router
                    ):
                        raise RuntimeError("LXMF runtime changed before fallback enqueue")

                    # This RLock is the enqueue linearization boundary. Competing
                    # recipient proof either wins before this point and cancels,
                    # or waits until handle_outbound has accepted ownership. The
                    # lock is reentrant because shipping LXMF can synchronously
                    # invoke our callbacks from handle_outbound.
                    with callback_lock:
                        if callback_state["outcome"] is not None:
                            return
                        m.desired_method = LXMF.LXMessage.PROPAGATED
                        m.packed = None
                        m.pack()
                        if m.hash != original_hash or m.propagation_packed is None:
                            raise ValueError("propagation repack changed canonical message")
                        m.state = LXMF.LXMessage.OUTBOUND
                        m.delivery_attempts = 0
                        m.progress = 0.0
                        m.register_failed_callback(_on_propagated_failed)
                        # This state means fallback submission has begun. It is
                        # deliberately emitted before handle_outbound so a
                        # synchronous relay acceptance/failure callback cannot
                        # overtake the Cloud Upload state.
                        _emit_lifecycle(
                            m,
                            "retrying_propagated",
                            "propagation-fallback-admitted",
                        )
                        router.handle_outbound(m)
            except Exception:
                _emit_lifecycle(m, "failed", "propagated-enqueue-failed")

        def _on_primary_failed(m: "LXMF.LXMessage") -> None:
            if fallback_method != LXMF.LXMessage.PROPAGATED:
                _emit_lifecycle(m, "failed", "primary-failed")
                return

            with callback_lock:
                if callback_state["outcome"] is not None or callback_state["fallback_started"]:
                    return
                if getattr(router, "outbound_propagation_node", None) is None:
                    missing_node = True
                else:
                    callback_state["fallback_started"] = True
                    missing_node = False

            if missing_node:
                _emit_lifecycle(m, "failed", "no-propagation-node")
                return

            try:
                threading.Thread(
                    target=_enqueue_propagated,
                    args=(m,),
                    name="ColumbaPropagationFallback",
                    daemon=True,
                ).start()
            except Exception:
                _emit_lifecycle(m, "failed", "propagated-enqueue-failed")

        msg.register_delivery_callback(_on_delivered)
        if desired_method == LXMF.LXMessage.PROPAGATED:
            msg.register_failed_callback(_on_propagated_failed)
        else:
            msg.register_failed_callback(_on_primary_failed)

        router.handle_outbound(msg)

        message_hash = msg.hash.hex() if msg.hash is not None else ""
        return {"ok": True, "reason": "queued", "message_hash": message_hash}


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

    `form_fields` is a `dict[str, str]` (exact `field_*` / `var_*` keys)
    for POST-style submissions; pass `None` for a plain GET-equivalent
    fetch. The mapping is passed directly to `RNS.Link.request`, which owns
    request framing. Pre-packing it turns the server-side request data into
    bytes instead of a dict, so node apps such as rngit reject the request."""
    with _lock:
        if not _state["started"]:
            return {"ok": False, "status": "not-started", "data": b"", "content_type": ""}
    try:
        dest_hash = bytes.fromhex(dest_hash_hex)
    except ValueError:
        return {"ok": False, "status": "bad-hash", "data": b"", "content_type": ""}

    # Resolve both the route and announced node identity before opening the
    # link. A cold first request must wait for the path response instead of
    # merely triggering discovery and requiring the user to retry manually.
    path_result = resolve_path(
        dest_hash_hex,
        timeout_seconds=min(15.0, max(0.0, float(timeout))),
    )
    if not path_result["ok"]:
        return {"ok": False, "status": "no-path", "data": b"", "content_type": ""}

    peer_identity = RNS.Identity.recall(dest_hash)
    if peer_identity is None:
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

    if not link_ready.wait(timeout=min(20.0, timeout)):
        try:
            link.teardown()
        except Exception:
            pass
        return {"ok": False, "status": "link-failed", "data": b"", "content_type": ""}

    # Identify on the link AFTER it reaches ACTIVE (link_ready) — link.identify
    # sends an encrypted identity-proof packet that a PENDING link cannot send,
    # so identifying before the wait silently no-ops. The remote needs this;
    # nomadnet's node app expects it for stateful pages.
    # Snapshot the identity under _lock: a concurrent reset_identity()/stop()
    # can null _state["identity"] between the None-check and link.identify(),
    # making identify() silently no-op on None (mirrors link_identify()).
    with _lock:
        active_identity = _state["identity"]
    try:
        if active_identity is not None:
            link.identify(active_identity)
    except Exception:
        pass

    # RNS.Link.request owns request-data framing. Pass the mapping directly so
    # the remote path handler receives a dict rather than pre-packed bytes.
    request_data: Any = dict(form_fields) if form_fields else None

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


@_balanced_runtime_teardown
def reset_identity(identity_path: str) -> None:
    """Delete identity bytes on disk and tear down state. Caller must call
    start() again after this. Safe to call when not started."""
    # Cancel native stamp work before acquiring the bridge lock; cancellation
    # callbacks are foreign process-global state and must not participate in
    # bridge lock ordering.
    _uninstall_native_stamp_generator()
    global _telephony_destination
    with _lock:
        # Tear down the router first (stops its LXMRouter background threads),
        # then Reticulum — same order as stop(). Without the router teardown a
        # follow-on start() spins up a second LXMRouter pointing at the same
        # lxmf-storage SQLite, and the two threads race over the database.
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
        # Clear the RNS.Reticulum singleton + exit-handler flags so the start()
        # this function's docstring requires can actually re-init. exit_handler()
        # leaves _Reticulum__instance set, so a follow-on __init__ would raise
        # "Attempt to reinitialise Reticulum, when it was already running" and the
        # app could only recover via a process restart. Mirrors stop().
        try:
            RNS.Reticulum._Reticulum__instance = None
            RNS.Reticulum._Reticulum__exit_handler_ran = False
            RNS.Reticulum._Reticulum__interface_detach_ran = False
        except Exception:
            pass
        # Drain RNS.Transport's process-global class state too — exit_handler()
        # leaves destinations/interfaces/path tables populated, so the start()
        # this function's docstring requires would otherwise raise "Attempt to
        # register an already registered destination" and only a process restart
        # could recover. Same teardown stop() does.
        _clear_transport_class_state()
        # Snapshot the links + clear inside the lock; tear them down OUTSIDE it
        # (below) so a synchronous _on_closed — which re-acquires the
        # non-reentrant _lock — can't deadlock the bridge (mirrors stop()).
        links_to_teardown = list(_links.values())
        _links.clear()
        _telephony_destination = None
        # Drop registered BLE callbacks + the BLE bridge handle so the
        # start() this function's docstring requires doesn't invoke closures
        # bound to the torn-down driver / Swift bridge (mirrors stop()).
        clear_ble_callbacks()
        global _ble_bridge_handle, _announce_generation
        _ble_bridge_handle = None
        # Supersede any in-flight delayed re-announce thread (see start()).
        _announce_generation += 1
        _state.update({
            "started": False,
            "reticulum": None,
            "router": None,
            "identity": None,
            "destination": None,
            "handler": None,
            "telephony_destination": None,
        })
    # Outside the lock: tear down the snapshotted links.
    for _link in links_to_teardown:
        try:
            _link.teardown()
        except Exception:
            pass
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
                # AutoInterfacePeer (spawned dynamically) sets `name=None`,
                # so coerce to empty string — JSON null breaks Swift's
                # String decoder and silently drops the whole snapshot.
                section_name = getattr(iface, "name", None) or ""
                iface_info.append({
                    "section_name": section_name,
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


def discovery_json() -> str:
    """JSON-serialized interface-discovery state for the Swift bridge.

    Mirrors `status_json()` contract: always returns a JSON object string,
    never raises, so PythonBridge.discovery() can decode unconditionally.
    Read path uses the on-disk announce store (RNS.Reticulum.discovered_interfaces())
    so it lists previously-heard announces even before discovery is enabled.
    """
    import json as _json
    out: dict[str, Any] = {"discovered": [], "enabled": False, "autoconnected": []}
    if not _state.get("started"):
        return _json.dumps(out)
    try:
        infos = RNS.Reticulum.discovered_interfaces() or []
        for info in infos:
            d: dict[str, Any] = {}
            for k, v in dict(info).items():
                if isinstance(v, (bytes, bytearray)):
                    # transport_id / network_id arrive as msgpack bytes —
                    # the Swift model wants hex strings (matches RNS.hexrep).
                    v = bytes(v).hex()
                d[k] = v
            out["discovered"].append(d)
    except Exception as e:
        RNS.log(f"discovery_json: list_discovered_interfaces failed: {e}", RNS.LOG_DEBUG)
    try:
        out["enabled"] = bool(RNS.Reticulum.should_autoconnect_discovered_interfaces())
    except Exception:
        pass
    try:
        endpoints = set()
        for iface in list(RNS.Transport.interfaces):
            if hasattr(iface, "autoconnect_hash"):
                s = str(iface)
                if s:
                    endpoints.add(s)
        out["autoconnected"] = sorted(endpoints)
    except Exception:
        pass
    return _json.dumps(out)


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


def diagnose_path_table() -> str:
    """Dump the first N entries of `RNS.Transport.path_table` with the
    receiving-interface attribution we'd plumb up to a Node Details view.
    Mirrors what `[Interface Heard]` should render — useful when we can't
    screenshot the actual UI."""
    lines: list[str] = []
    try:
        pt = RNS.Transport.path_table
    except Exception as e:
        return f"path_table unavailable: {e}"
    if not pt:
        return "path_table is empty (no announces received yet)"
    lines.append(f"path_table count={len(pt)}")
    for i, (dh, entry) in enumerate(list(pt.items())[:10]):
        try:
            dest_hex = dh.hex() if isinstance(dh, (bytes, bytearray)) else str(dh)
            iface = entry[5] if entry and len(entry) > 5 else None
            iface_name = getattr(iface, "name", None) or (str(iface) if iface else "<none>")
            timestamp = entry[0] if entry else "?"
            hops = entry[2] if entry and len(entry) > 2 else "?"
            lines.append(f"  [{i}] dest={dest_hex[:16]} hops={hops} ts={timestamp} iface={iface_name}")
        except Exception as e:
            lines.append(f"  [{i}] dump err: {e}")
    return "\n".join(lines)


def diagnose_auto_interface() -> str:
    """Introspect the running AutoInterface instance(s) and report the state
    of peer discovery so we can tell whether multicast join / socket bind
    is working at all."""
    import socket as _socket
    lines: list[str] = []
    try:
        ifs = RNS.Transport.interfaces
    except Exception as e:
        return f"Transport.interfaces unavailable: {e}"
    all_types = [(type(i).__name__, getattr(i, "name", "?")) for i in ifs]
    lines.append(f"all_interfaces ({len(ifs)}): {all_types}")
    autos = [i for i in ifs if type(i).__name__ == "AutoInterface"]
    if not autos:
        return "\n".join(lines + ["no AutoInterface instance in Transport.interfaces"])
    for ai in autos:
        lines.append(f"name={getattr(ai, 'name', '?')} online={getattr(ai, 'online', '?')}")
        lines.append(f"  group_id={getattr(ai, 'group_id', '?')}")
        lines.append(f"  discovery_scope={getattr(ai, 'discovery_scope', '?')}")
        lines.append(f"  discovery_port={getattr(ai, 'discovery_port', '?')}")
        lines.append(f"  data_port={getattr(ai, 'data_port', '?')}")
        try:
            lines.append(f"  ifnames={list(getattr(ai, 'ifnames', []) or [])}")
        except Exception:
            pass
        try:
            ifs_addrs = getattr(ai, "interface_servers", None) or getattr(ai, "ifaddrs", None)
            lines.append(f"  ifaddrs/servers={ifs_addrs!r}")
        except Exception:
            pass
        try:
            peers = getattr(ai, "peers", {}) or {}
            lines.append(f"  peers={len(peers)} {list(peers.keys())[:5]}")
        except Exception:
            pass
        try:
            # AutoInterface has a per-ifname socket dict; introspect bindings.
            sockets = []
            for attr in ("multicast_sockets", "sockets", "interface_servers"):
                val = getattr(ai, attr, None)
                if val:
                    sockets.append(f"{attr}={val!r}")
            if sockets:
                lines.append("  " + "; ".join(sockets))
        except Exception:
            pass
    # Also list the local IP interfaces visible to Python — confirms what
    # iOS is exposing. If en0 isn't here, AutoInterface has nothing to bind.
    import platform as _platform
    lines.append(f"  platform.system()={_platform.system()!r} platform.platform()={_platform.platform()!r}")
    lines.append(f"  AF_INET={_socket.AF_INET} AF_INET6={_socket.AF_INET6}")
    # Try RNS' own netinfo first (uses libc getifaddrs via ctypes).
    try:
        from RNS.Interfaces.util import netinfo as _netinfo
        ifs_seen = _netinfo.interfaces()
        lines.append(f"  netinfo.interfaces() (n={len(ifs_seen)}): {ifs_seen}")
        # Specifically probe en0 — that's the WiFi interface on iOS.
        for ifname in ("en0", "en1", "awdl0"):
            if ifname in ifs_seen:
                try:
                    addrs = _netinfo.ifaddresses(ifname)
                    lines.append(f"    {ifname}: {addrs}")
                except Exception as e:
                    lines.append(f"    {ifname}: ifaddresses err={e}")
        # Also poke directly at the libc layer to surface raw sa_familiy
        # values for en0 — distinguishes "struct layout wrong" from
        # "iOS sandbox returns nothing".
        try:
            import ctypes as _ct
            libc = _ct.CDLL(_ct.util.find_library("c"), use_errno=True)
            class ifaddrs(_ct.Structure): pass
            ifaddrs._fields_ = [
                ("ifa_next", _ct.POINTER(ifaddrs)),
                ("ifa_name", _ct.c_char_p),
                ("ifa_flags", _ct.c_uint),
                ("ifa_addr", _ct.POINTER(_ct.c_uint8 * 16)),
            ]
            ptr = _ct.POINTER(ifaddrs)()
            if libc.getifaddrs(_ct.byref(ptr)) == 0:
                en0_seen = []
                walker = ptr
                while walker:
                    name = walker[0].ifa_name.decode("utf-8", errors="replace") if walker[0].ifa_name else "<null>"
                    if name in ("en0", "en1"):
                        raw = walker[0].ifa_addr
                        if raw:
                            buf = list(bytes(raw[0]))
                            en0_seen.append(f"{name} sa_len={buf[0]} sa_family={buf[1]} bytes={buf[:8]}")
                        else:
                            en0_seen.append(f"{name} addr=NULL")
                    walker = walker[0].ifa_next
                libc.freeifaddrs(ptr)
                lines.append(f"  raw getifaddrs en0/en1: {en0_seen}")
        except Exception as e:
            lines.append(f"  raw getifaddrs probe failed: {e}")
    except Exception as e:
        lines.append(f"  netinfo unavailable: {e}")
    try:
        host_info = _socket.gethostbyname_ex(_socket.gethostname())
        lines.append(f"  hostname={host_info[0]} addrs={host_info[2]}")
    except Exception as e:
        lines.append(f"  host lookup failed: {e}")
    return "\n".join(lines)


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
