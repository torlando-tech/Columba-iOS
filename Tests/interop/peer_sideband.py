"""Sideband headless peer.

Wraps a `SidebandCore` daemon instance running in-process. Provides:
  - lifecycle (start / stop / identity hash)
  - typed send helpers per LXMF field (text, image, file, audio, telemetry,
    icon-appearance)
  - DB-backed receive verification (`wait_for_message`)

Why in-process rather than subprocess:
  - SidebandCore runs its own background threads for RNS / LXMF — once
    `start()` returns, the daemon is live without us having to manage a
    child process.
  - Direct method calls beat shelling out for sends (no JSON marshaling,
    typed payloads).
  - Faster shutdown (no process tear-down between tests; the DB is the
    cross-test boundary).

The Sideband source tree must be on `PYTHONPATH`. `conftest.py` arranges
that before any test imports this module.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Optional


@dataclass
class ReceivedMessage:
    """One inbound row from `lxm` table in `sideband.db`. Matches the
    columns the harness asserts against; other columns are ignored."""

    lxm_hash: bytes
    source_hash: bytes
    content: bytes
    title: bytes
    fields: dict  # msgpack-decoded LXMF field map (int key -> value)
    received_at: float

    @property
    def content_text(self) -> str:
        return self.content.decode("utf-8", errors="replace")


class SidebandPeer:
    """Headless Sideband daemon. Construct, call `start()`, then
    `identity_hex` is populated and `send_text` / `wait_for_message`
    are usable."""

    def __init__(
        self,
        sideband_src: str,
        config_dir: Optional[str] = None,
        prop_node_hex: Optional[str] = None,
    ):
        self.sideband_src = sideband_src
        # `mkdtemp` so parallel-running suites don't collide on a fixed path.
        self.config_dir = config_dir or tempfile.mkdtemp(prefix="sideband-peer-")
        self._owns_config_dir = config_dir is None
        self._core = None
        self._db_path = os.path.join(
            self.config_dir, "app_storage", "sideband.db"
        )
        self._known_lxm_hashes: set[bytes] = set()
        self._prop_node_hex = prop_node_hex
        self._taps: list = []

    # ---- lifecycle -----------------------------------------------------

    def _attach_inbound_tap(self) -> None:
        """Wrap Sideband's existing LXMRouter delivery callback so the
        test harness sees EVERY inbound LXMessage, even ones Sideband
        drops or routes to non-LXM tables (e.g. telemetry-only frames
        that bypass the `lxm` table because their content is empty).

        Without this, telemetry-only interop tests have no observable:
        Sideband's strict `Telemeter.from_packed()` parser rejects
        Columba's JSON-encoded FIELD_TELEMETRY and the message
        disappears.

        The tap is a Python closure that calls the original callback
        first (so Sideband's own state machine still runs), then
        appends to `self._taps`. Tests inspect `_taps` via
        `wait_for_tapped_message`."""
        self._taps = []
        router = self._core.message_router
        # `__delivery_callback` is name-mangled; expose via underscore prefix.
        # Guard explicitly: if a Sideband refactor renames/removes it, accessing
        # the attribute would raise AttributeError deep inside `_wrapped`,
        # silently skipping Sideband's own delivery processing so every
        # `wait_for_tapped_message` times out with no actionable cause.
        assert hasattr(router, "_LXMRouter__delivery_callback"), (
            "LXMRouter no longer exposes __delivery_callback — Sideband may have "
            "renamed or removed it. Update _attach_inbound_tap."
        )
        original = router._LXMRouter__delivery_callback
        # On every tap we also emit a one-line stderr log so a pytest run
        # with `-s` shows inbound state — invaluable when an assertion
        # fails because the content didn't match (vs no message at all).
        def _wrapped(lxm):
            try:
                self._taps.append(lxm)
                try:
                    import sys
                    src = lxm.source_hash.hex() if lxm.source_hash else "?"
                    msg = (lxm.hash.hex()[:16] + "…") if getattr(lxm, "hash", None) else "?"
                    content = (lxm.content or b"").decode("utf-8", "replace")
                    sig = getattr(lxm, "signature_validated", None)
                    fields = sorted((lxm.fields or {}).keys())
                    print(f"[sideband-tap] src={src} msg={msg} content={content!r} "
                          f"sig={sig} fields={fields}", file=sys.stderr, flush=True)
                except Exception:
                    pass
            finally:
                if original is not None:
                    return original(lxm)
        self._core.message_router._LXMRouter__delivery_callback = _wrapped

    def wait_for_tapped_message(
        self,
        from_hex: str,
        field_id: Optional[int] = None,
        content_match: Optional[str] = None,
        baseline: Optional[int] = None,
        timeout: float = 30.0,
        poll: float = 0.25,
    ):
        """Block until the inbound-tap captures an LXMessage matching
        the filter. Returns the raw LXMessage so callers can read
        `lxm.fields[FIELD_*]` directly — useful for fields Sideband's
        _db_save_lxm filters out (telemetry-only messages) or formats
        non-standard (Telemeter-vs-JSON encoding mismatch).

        Filtering precedence:
          * `from_hex` (required): only match messages whose source_hash
            equals this LXMF delivery destination.
          * `field_id` (optional): require this LXMF FIELD_* key be present.
          * `content_match` (optional): require the message's UTF-8 content
            equal this string. Use when many tests share a sender and
            you need to disambiguate the specific message the test sent.
          * `baseline` (optional): only scan taps captured at index >=
            this value. Defaults to **0** so a tap that landed *before*
            this call started is still discoverable — the inbound RNS
            stack frequently delivers a message before the test's
            `wait_for_tapped_message` runs (the proof + LXMF callback
            both fire on background threads). Pass a snapshot of
            `len(peer._taps)` taken *before* the send when you need
            strict "must arrive after this point" semantics."""
        from_bytes = bytes.fromhex(from_hex)
        deadline = time.time() + timeout
        if baseline is None:
            baseline = 0
        while time.time() < deadline:
            for lxm in self._taps[baseline:]:
                if lxm.source_hash != from_bytes:
                    continue
                if field_id is not None and field_id not in (lxm.fields or {}):
                    continue
                if content_match is not None:
                    actual = (lxm.content or b"").decode("utf-8", "replace")
                    if actual != content_match:
                        continue
                return lxm
            time.sleep(poll)
        raise AssertionError(
            f"Sideband's inbound tap did not capture a matching "
            f"message within {timeout}s (from={from_hex}, "
            f"field_id={field_id}, content_match={content_match!r})"
        )

    def start(self, ready_timeout: float = 30.0) -> None:
        if self.sideband_src not in sys.path:
            sys.path.insert(0, self.sideband_src)

        # SidebandCore re-uses the default `~/.reticulum/config` for its
        # RNS instance, which on this host shares with the host rnsd via
        # the standard `share_instance` port. That's what we want — same
        # transport, same path table as the emulator's Columba.
        from sbapp.sideband.core import SidebandCore

        self._core = SidebandCore(
            None,
            config_path=self.config_dir,
            is_client=False,
            verbose=False,
            quiet=True,
            is_daemon=True,
        )
        self._core.version_str = "v-interop-test"
        self._core.start()

        deadline = time.time() + ready_timeout
        while time.time() < deadline:
            if self._core.getstate("core.started") is True:
                break
            time.sleep(0.2)
        else:
            raise TimeoutError(
                f"Sideband core failed to reach started state within "
                f"{ready_timeout}s"
            )

        # Seed the "known LXM hashes" with whatever's already in the DB
        # so `wait_for_message` only sees rows we observe arriving live.
        # Useful when a config dir is reused across runs.
        with self._db_connect() as conn:
            for (h,) in conn.execute("SELECT lxm_hash FROM lxm"):
                self._known_lxm_hashes.add(h)

        # Hook the LXMRouter so the harness sees every inbound message,
        # including ones Sideband filters out before they hit any DB
        # table (telemetry-only frames, malformed-but-deliverable fields,
        # etc.). Must run AFTER `start()` registers Sideband's own
        # delivery callback — we wrap it.
        self._attach_inbound_tap()

        # Optional propagation-node setup — required for PROPAGATED
        # method round-trips. Sideband would normally auto-pick one
        # from received propagation-node announces, but for a
        # deterministic test we set it explicitly.
        if self._prop_node_hex is not None:
            try:
                self._core.set_active_propagation_node(
                    bytes.fromhex(self._prop_node_hex)
                )
            except Exception:  # noqa: BLE001
                # Sideband logs internally; surface only if a later
                # propagation-sync call fails.
                pass

    def sync_propagation_messages(self, limit: int = 50) -> None:
        """Pull queued propagated messages from the configured
        propagation node into Sideband's local LXM store. Used by
        PROPAGATED tests after the sender's upload has settled."""
        if self._core is None:
            raise RuntimeError("Sideband peer not started")
        router = self._core.message_router
        # `request_messages_from_propagation_node` returns synchronously
        # after firing the request; the actual sync continues on RNS
        # threads. Callers should then poll the DB / tap as usual.
        router.request_messages_from_propagation_node(
            self._core.identity,
            max_messages=limit,
        )

    def stop(self) -> None:
        """Best-effort core shutdown. Sideband doesn't expose a clean
        stop API in daemon mode — we close the DB handle and rely on
        process exit to reap RNS threads. CI runners should treat each
        pytest session as the unit of teardown."""
        if self._core is not None:
            # SidebandCore's teardown is `cleanup()` (the older private
            # `__exit_handler` was removed). On the host it connects to the
            # shared rnsd/lxmd instance, so cleanup() is intentionally a near
            # no-op (RNS teardown belongs to the shared instance, not us); we
            # still call it for DB flush + future-proofing, and rely on process
            # exit to reap threads. Guard the name (like _attach_inbound_tap
            # does for __delivery_callback) so a future Sideband rename surfaces
            # loudly instead of silently skipping teardown.
            if hasattr(self._core, "cleanup"):
                try:
                    self._core.cleanup()
                except Exception:  # noqa: BLE001
                    # Sideband logs its own teardown errors; suppress here.
                    pass
            else:
                print(
                    "[peer_sideband] WARNING: SidebandCore.cleanup is gone — "
                    "Sideband may have renamed its teardown; RNS threads can leak "
                    "between sessions. Update peer_sideband.stop().",
                    flush=True,
                )
            self._core = None
        if self._owns_config_dir and os.path.isdir(self.config_dir):
            shutil.rmtree(self.config_dir, ignore_errors=True)

    @property
    def identity_hex(self) -> str:
        if self._core is None or self._core.lxmf_destination is None:
            raise RuntimeError("Sideband peer not started")
        return self._core.lxmf_destination.hash.hex()

    @property
    def identity_bytes(self) -> bytes:
        return bytes.fromhex(self.identity_hex)

    # ---- sending -------------------------------------------------------

    def send_text(
        self,
        dest_hex: str,
        content: str,
        propagation: bool = False,
    ) -> bool:
        return self._send(dest_hex, content, propagation)

    def send_image(
        self,
        dest_hex: str,
        content: str,
        image_bytes: bytes,
        image_format: str = "png",
    ) -> bool:
        """LXMF `FIELD_IMAGE` is `[format_string, bytes]`. Sideband's
        `image` kwarg accepts that pair directly."""
        return self._send(
            dest_hex,
            content,
            propagation=False,
            image=[image_format, image_bytes],
        )

    def send_file(
        self,
        dest_hex: str,
        content: str,
        filename: str,
        data: bytes,
    ) -> bool:
        """LXMF `FIELD_FILE_ATTACHMENTS` element is `[name_bytes, data_bytes]`;
        Sideband wraps `[attachment]` into the field list itself."""
        return self._send(
            dest_hex,
            content,
            propagation=False,
            attachment=[filename.encode("utf-8"), data],
        )

    def send_audio(
        self,
        dest_hex: str,
        content: str,
        audio_bytes: bytes,
        codec_tag: int = 0,
    ) -> bool:
        """LXMF `FIELD_AUDIO` is `[codec_int, bytes]`. Sideband's `audio`
        kwarg passes the pair through unchanged."""
        return self._send(
            dest_hex,
            content,
            propagation=False,
            audio=[codec_tag, audio_bytes],
        )

    def send_location_telemetry(
        self,
        dest_hex: str,
        lat: float,
        lon: float,
        alt: float = 0.0,
        speed: float = 0.0,
        bearing: float = 0.0,
        accuracy: float = 1.0,
        icon: Optional[tuple] = None,
    ) -> bool:
        """Send a canonical Sideband-format `FIELD_TELEMETRY` blob —
        msgpack-encoded `Telemeter` dict with `SID_TIME` + `SID_LOCATION`.
        Built from Sideband's `sense.py` Telemeter so the on-wire bytes
        are byte-identical to what a real Sideband install would emit.

        `icon`, if given, is `(icon_name, fg_hex, bg_hex)` where the hex
        strings are 6-char `RRGGBB`. It rides along as
        `FIELD_ICON_APPEARANCE` (0x04) in the canonical Sideband/Android
        wire form `[name, fg_rgb_bytes(3), bg_rgb_bytes(3)]` so the iOS
        map marker renders the peer's MDI glyph + colours rather than the
        initial-letter fallback. Lets the interop suite pin the inbound
        FIELD_ICON_APPEARANCE → `PeerLocation.iconAppearance` → marker
        path alongside the telemetry decode."""
        if self._core is None:
            raise RuntimeError("Sideband peer not started")
        # Use Sideband's own Telemeter — avoids drift from the canonical
        # encoder. `from_packed=True` skips the GPS sensor wiring; we
        # synthesize Location directly + manually populate `.data` to
        # the shape Location.pack() expects.
        from sbapp.sideband.sense import Telemeter
        import LXMF
        t = Telemeter(from_packed=True)
        t.synthesize("location")
        loc = t.sensors["location"]
        loc.data = {
            "latitude": lat,
            "longitude": lon,
            "altitude": alt,
            "speed": speed,
            "bearing": bearing,
            "accuracy": accuracy,
            "last_update": int(time.time()),
        }
        packed = t.packed()
        fields = {LXMF.FIELD_TELEMETRY: packed}
        if icon is not None:
            name, fg_hex, bg_hex = icon
            fields[LXMF.FIELD_ICON_APPEARANCE] = [
                name,
                bytes.fromhex(fg_hex),
                bytes.fromhex(bg_hex),
            ]
        return self.send_with_fields(
            dest_hex,
            content="",
            fields=fields,
        )

    def _send(self, dest_hex: str, content: str, propagation: bool, **kw) -> bool:
        if self._core is None:
            raise RuntimeError("Sideband peer not started")
        dest_bytes = bytes.fromhex(dest_hex)
        # `SidebandCore.send_message` returns True on enqueue, not on
        # actual delivery — delivery confirmation is observed via the
        # receiving peer's `wait_for_message`.
        return self._core.send_message(
            content,
            dest_bytes,
            propagation,
            **kw,
        )

    def send_with_fields(
        self,
        dest_hex: str,
        content: str,
        fields: dict,
        propagation: bool = False,
    ) -> bool:
        """Bypass `send_message` and construct the LXMessage directly so
        callers can attach arbitrary `FIELD_*` entries (e.g.
        `FIELD_TELEMETRY` blobs that aren't Telemeter-shaped, or
        `FIELD_ICON_APPEARANCE` triples without using Sideband's
        appearance config flags).

        Mirrors `SidebandCore.send_message`'s method-selection: prefer
        OPPORTUNISTIC when no live delivery link exists and we have a
        ratchet for the destination (sub-second send), fall back to
        DIRECT otherwise. Hardcoding DIRECT used to add 20-30s of link
        establishment delay for tests against freshly-bootstrapped
        peers."""
        if self._core is None:
            raise RuntimeError("Sideband peer not started")
        import LXMF
        import RNS
        dest_bytes = bytes.fromhex(dest_hex)
        dest_identity = RNS.Identity.recall(dest_bytes)
        if dest_identity is None:
            return False
        dest = RNS.Destination(
            dest_identity,
            RNS.Destination.OUT,
            RNS.Destination.SINGLE,
            "lxmf",
            "delivery",
        )
        source = self._core.lxmf_destination
        if propagation:
            desired_method = LXMF.LXMessage.PROPAGATED
        elif (
            not self._core.message_router.delivery_link_available(dest_bytes)
            and RNS.Identity.current_ratchet_id(dest_bytes) is not None
        ):
            desired_method = LXMF.LXMessage.OPPORTUNISTIC
        else:
            desired_method = LXMF.LXMessage.DIRECT
        lxm = LXMF.LXMessage(
            dest,
            source,
            content,
            title="",
            desired_method=desired_method,
            fields=fields,
        )
        # No ingest into the local DB — outbound side of an interop
        # test doesn't need to persist a local copy.
        self._core.message_router.handle_outbound(lxm)
        return True

    # ---- receiving (DB-backed) -----------------------------------------

    def wait_for_message(
        self,
        from_hex: Optional[str] = None,
        content_predicate=None,
        timeout: float = 30.0,
        poll: float = 0.25,
    ) -> ReceivedMessage:
        """Poll `sideband.db` for an inbound LXM row matching the filters.

        - `from_hex`: source destination hash to match.
        - `content_predicate`: callable taking `ReceivedMessage`, returning
          True when matched. Default: any unseen inbound row.
        - `timeout`: total wait budget in seconds.

        Inbound rows are identified by tracking which `lxm_hash` values
        were present at `start()` time — anything new is treated as a
        live arrival. This way the suite tolerates persisted history in
        a re-used config dir.
        """
        from_bytes = bytes.fromhex(from_hex) if from_hex else None
        deadline = time.time() + timeout
        last_err = None
        while time.time() < deadline:
            try:
                with self._db_connect() as conn:
                    rows = conn.execute(
                        # `lxm` table schema (Sideband core.py __db_init):
                        # lxm_hash, dest, source, title, tx_ts, rx_ts,
                        # state, method, t_encrypted, t_encryption,
                        # data (the plaintext-packed LXMessage), extra
                        "SELECT lxm_hash, source, title, data, rx_ts, method "
                        "FROM lxm ORDER BY rx_ts DESC LIMIT 50"
                    ).fetchall()
            except sqlite3.OperationalError as e:
                # Sideband may briefly hold a write lock; back off + retry.
                last_err = e
                time.sleep(poll)
                continue

            for lxm_hash, source, title, data, rx_ts, method in rows:
                if lxm_hash in self._known_lxm_hashes:
                    continue
                if from_bytes is not None and source != from_bytes:
                    continue
                # `data` is the plaintext-packed LXMessage bytes (dest
                # + source + signature + msgpacked [ts, title, content,
                # fields]). Decode to recover content + fields.
                msg = self._decode_lxm(
                    lxm_hash, source, title, data, rx_ts, method
                )
                if content_predicate is None or content_predicate(msg):
                    self._known_lxm_hashes.add(lxm_hash)
                    return msg
            time.sleep(poll)

        raise AssertionError(
            f"Sideband did not receive a matching message within {timeout}s "
            f"(from_hex={from_hex}, last_db_err={last_err})"
        )

    # ---- internals -----------------------------------------------------

    def wait_for_telemetry(
        self,
        from_hex: str,
        timeout: float = 30.0,
        poll: float = 0.5,
    ) -> bytes:
        """Sideband persists inbound FIELD_TELEMETRY payloads to the
        `telemetry` table (NOT `lxm`), because telemetry-only LXMessages
        have empty content/title and `_db_message` skips them. This
        polls that table for a fresh row from `from_hex` and returns
        the raw payload bytes."""
        from_bytes = bytes.fromhex(from_hex)
        # Snapshot existing rows to ignore — only "new since this call"
        # qualifies as a live arrival.
        with self._db_connect() as conn:
            baseline = {
                row[0] for row in conn.execute(
                    "SELECT id FROM telemetry WHERE dest_context = ?",
                    (from_bytes,),
                )
            }
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                with self._db_connect() as conn:
                    rows = conn.execute(
                        "SELECT id, data FROM telemetry "
                        "WHERE dest_context = ? ORDER BY id DESC LIMIT 50",
                        (from_bytes,),
                    ).fetchall()
            except sqlite3.OperationalError:
                time.sleep(poll)
                continue
            for row_id, data in rows:
                if row_id in baseline:
                    continue
                return bytes(data)
            time.sleep(poll)
        raise AssertionError(
            f"Sideband did not persist a telemetry row from {from_hex} "
            f"within {timeout}s"
        )

    def _db_connect(self) -> sqlite3.Connection:
        # `check_same_thread=False` because the LXMRouter thread is the
        # actual writer; we're a separate reader thread.
        return sqlite3.connect(
            self._db_path, timeout=5.0, check_same_thread=False
        )

    def _decode_lxm(
        self, lxm_hash: bytes, source: bytes, title: bytes, data: bytes,
        rx_ts: float, method: int,
    ) -> ReceivedMessage:
        """Re-hydrate an LXMessage from its packed `data` blob so tests
        can assert on fields. `original_method` matters because LXMF's
        wire format differs across DIRECT / OPPORTUNISTIC / PROPAGATED;
        passing it lets `unpack_from_bytes` skip a probe + decode in one
        shot. Mirrors Sideband core.py's own DB-read path."""
        import LXMF
        try:
            lxm = LXMF.LXMessage.unpack_from_bytes(
                data, original_method=method
            )
            content = lxm.content
            fields = lxm.fields or {}
        except Exception:  # noqa: BLE001
            # If unpack fails (e.g. partial row), surface the raw bytes
            # so the test can fail loudly rather than match a half-message.
            content = data
            fields = {}
        return ReceivedMessage(
            lxm_hash=lxm_hash,
            source_hash=source,
            content=content if isinstance(content, (bytes, bytearray)) else
                    bytes(content, "utf-8"),
            title=title or b"",
            fields=fields,
            received_at=float(rx_ts) if rx_ts is not None else 0.0,
        )
