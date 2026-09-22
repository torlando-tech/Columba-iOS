"""Control-channel wire codec for the node-service v1 contract (pure Python).

Mirrors the Swift ``ColumbaNode/Control`` layer field-for-field so the SAME
bytes the app (Swift) writes can be read by the NE engine (Python RNS) and
vice-versa:

* Framing (contract 6): magic ``[0xF5, 0x02]`` + a UTF-8 JSON payload, with a
  HARD 64 KiB envelope cap INCLUDING the two framing bytes.
* A frame beginning ``0xF5`` with an unknown/missing version byte is a hard
  control-protocol error - it must NOT fall through to any legacy protocol.
* ``Request`` / ``Reply`` are tagged-union JSON exactly as the Swift
  ``ControlTypes`` produce them, so a Swift request and a Python request are
  byte-identical for the same logical value.

The complete command body is NEVER sent inline: the app stages it durably in
the shared store first, and ``admit`` carries only the commandID (contract
3.3, 6). This module only moves the small envelope - it has no RNS / LXMF
import, so it builds and tests on any CPython.
"""

from __future__ import annotations

import json
from typing import Any, Dict, List, Optional, Tuple

from .canonical import canonical_bytes

__all__ = [
    "ControlChannelError",
    "MAGIC",
    "MAX_ENVELOPE_BYTES",
    "framing_error",
    "encode_envelope",
    "decode_payload",
    "Request",
    "Reply",
]


class ControlChannelError(ValueError):
    """A frame that violates the control-channel protocol."""

    def __init__(self, kind: str, detail: str = "") -> None:
        self.kind = kind
        self.detail = detail
        super().__init__(f"{kind}: {detail}" if detail else kind)


#: Contract framing magic (contract 6): 0xF5 identifies control, 0x02 this
#: version. Must match ``ControlChannel.magic`` in Swift exactly.
MAGIC: bytes = bytes([0xF5, 0x02])

#: Hard envelope cap INCLUDING the two framing bytes. Must match
#: ``ControlChannel.maxEnvelopeBytes`` in Swift.
MAX_ENVELOPE_BYTES: int = 65_536  # 64 KiB


def framing_error(kind: str, detail: str = "") -> ControlChannelError:
    return ControlChannelError(kind, detail)


def encode_envelope(payload: bytes) -> bytes:
    """Build an envelope: magic + payload, enforcing the hard 64 KiB cap."""
    if len(MAGIC) + len(payload) > MAX_ENVELOPE_BYTES:
        raise framing_error(
            "envelopeTooLarge",
            f"{len(MAGIC) + len(payload)} > {MAX_ENVELOPE_BYTES}",
        )
    return MAGIC + payload


def decode_payload(envelope: bytes) -> bytes:
    """Strip and validate the framing.

    A frame beginning ``0xF5`` with a version byte other than ``0x02`` is a
    hard control-protocol error (unknown/truncated version) - it never
    falls through to a legacy protocol.
    """
    if len(envelope) < len(MAGIC):
        raise framing_error("truncated", "frame shorter than magic")
    if envelope[0] != MAGIC[0]:
        raise framing_error("badMagic", f"first byte 0x{envelope[0]:02x} != 0xF5")
    if envelope[1] != MAGIC[1]:
        raise framing_error(
            "badVersion",
            f"0xF5 with version 0x{envelope[1]:02x} != 0x02 (hard protocol error)",
        )
    return envelope[len(MAGIC):]


def _require(obj: Any, key: str) -> Any:
    if not isinstance(obj, dict) or key not in obj:
        raise ControlChannelError("malformed", f"missing key {key!r}")
    return obj[key]


def _opt(obj: Any, key: str) -> Any:
    if not isinstance(obj, dict):
        return None
    return obj.get(key)


# ---------------------------------------------------------------------------
# Request
# ---------------------------------------------------------------------------

class Request:
    """One request on the control channel (IDL ``record Request``).

    The four body tags are exactly the Swift ``RequestBody`` cases:
    ``hello`` / ``admit`` / ``query`` / ``act``. ``to_wire`` produces the
    same JSON object Swift produces for the same logical request.
    """

    def __init__(self, request_id: str, body_tag: str, value: Dict[str, Any]) -> None:
        self.request_id = request_id
        self.body_tag = body_tag
        self.value = value

    # -- constructors (mirror the Swift tag cases) --

    @staticmethod
    def hello(request_id: str, versions: List[Dict[str, int]],
              schema_min: int, schema_max: int) -> "Request":
        return Request(request_id, "hello", {
            "versions": versions,
            "schemaMin": schema_min,
            "schemaMax": schema_max,
        })

    @staticmethod
    def admit(request_id: str, session: Dict[str, Any], command_id: str) -> "Request":
        return Request(request_id, "admit", {
            "session": session,
            "commandID": command_id,
        })

    @staticmethod
    def query(request_id: str, session: Dict[str, Any],
              query: Dict[str, Any]) -> "Request":
        return Request(request_id, "query", {
            "session": session,
            "query": query,
        })

    @staticmethod
    def act(request_id: str, session: Dict[str, Any], action_id: str,
            action: Dict[str, Any]) -> "Request":
        return Request(request_id, "act", {
            "session": session,
            "actionID": action_id,
            "action": action,
        })

    # -- session helper (contract 6: every non-hello request carries it) --

    @staticmethod
    def session(version: Dict[str, int], store_epoch: str, boot_id: str) -> Dict[str, Any]:
        return {
            "version": version,
            "storeEpoch": store_epoch,
            "bootID": boot_id,
        }

    # -- encode --

    def to_wire(self) -> Dict[str, Any]:
        """The JSON object (dict) form - the same shape Swift emits."""
        return {
            "requestID": self.request_id,
            "body": {"tag": self.body_tag, "value": self.value},
        }

    def encode(self) -> bytes:
        """Canonical-framed envelope bytes: [0xF5 0x02] + canonical JSON."""
        return encode_envelope(canonical_bytes(self.to_wire()))

    # -- decode --

    @staticmethod
    def from_wire(obj: Any) -> "Request":
        request_id = str(_require(obj, "requestID"))
        body = _require(obj, "body")
        tag = str(_require(body, "tag"))
        value = _require(body, "value")
        return Request(request_id, tag, value)

    @classmethod
    def decode(cls, envelope: bytes) -> "Request":
        """Decode a framed envelope produced by the Swift side."""
        payload = decode_payload(envelope)
        obj = json.loads(payload.decode("utf-8"))
        return cls.from_wire(obj)

    def session_ctx(self) -> Optional[Dict[str, Any]]:
        """Return the session context if this is a non-hello request, else None."""
        if self.body_tag == "hello":
            return None
        return self.value.get("session")


# ---------------------------------------------------------------------------
# Reply
# ---------------------------------------------------------------------------

class Reply:
    """One reply on the control channel (IDL ``record Reply``).

    The result is a tagged union: ``{"tag": "success", "value": <ReplyValue>}``
    or ``{"tag": "failure", "value": <Error>}`` - exactly the Swift ``Reply``.
    """

    def __init__(self, request_id: str, result: Dict[str, Any],
                 store_epoch: Optional[str] = None,
                 boot_id: Optional[str] = None) -> None:
        self.request_id = request_id
        self.result = result
        self.store_epoch = store_epoch
        self.boot_id = boot_id

    # -- constructors (mirror the Swift result cases) --

    @staticmethod
    def success(request_id: str, reply_value: Dict[str, Any],
                store_epoch: str, boot_id: str) -> "Reply":
        return Reply(request_id, {"tag": "success", "value": reply_value},
                     store_epoch=store_epoch, boot_id=boot_id)

    @staticmethod
    def failure(request_id: str, error: Dict[str, Any],
                store_epoch: Optional[str] = None,
                boot_id: Optional[str] = None) -> "Reply":
        return Reply(request_id, {"tag": "failure", "value": error},
                     store_epoch=store_epoch, boot_id=boot_id)

    # -- admission / hello helpers (ReplyValue tags) --

    @staticmethod
    def hello_reply(request_id: str, descriptor: Dict[str, Any],
                    store_epoch: str, boot_id: str) -> "Reply":
        return Reply.success(request_id, {"tag": "hello", "value": descriptor},
                             store_epoch, boot_id)

    @staticmethod
    def admission_reply(request_id: str, command_record: Dict[str, Any],
                        store_epoch: str, boot_id: str) -> "Reply":
        return Reply.success(request_id,
                             {"tag": "admission", "value": command_record},
                             store_epoch, boot_id)

    # -- encode --

    def to_wire(self) -> Dict[str, Any]:
        obj: Dict[str, Any] = {
            "requestID": self.request_id,
            "result": self.result,
        }
        if self.store_epoch is not None:
            obj["storeEpoch"] = self.store_epoch
        if self.boot_id is not None:
            obj["bootID"] = self.boot_id
        return obj

    def encode(self) -> bytes:
        return encode_envelope(canonical_bytes(self.to_wire()))

    # -- decode --

    @staticmethod
    def from_wire(obj: Any) -> "Reply":
        request_id = str(_require(obj, "requestID"))
        result = _require(obj, "result")
        return Reply(request_id, result,
                     store_epoch=_opt(obj, "storeEpoch"),
                     boot_id=_opt(obj, "bootID"))

    @classmethod
    def decode(cls, envelope: bytes) -> "Reply":
        payload = decode_payload(envelope)
        obj = json.loads(payload.decode("utf-8"))
        return cls.from_wire(obj)

    @property
    def ok(self) -> bool:
        return isinstance(self.result, dict) and self.result.get("tag") == "success"

    @property
    def error(self) -> Optional[Dict[str, Any]]:
        if not self.ok and isinstance(self.result, dict):
            return self.result.get("value")
        return None
