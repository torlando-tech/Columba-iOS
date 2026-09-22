"""Pure, dependency-free canonical JSON (RFC 8785 / JCS) encoder + SHA-256.

This is the ONE place the canonical byte form of a node-service intent /
command / reply is produced, and it MUST agree byte-for-byte with the Swift
implementation in ``Sources/ColumbaNode/Support/JsonValue.swift``. Both are the
two halves of the same wire contract: the app (Swift) stages an intent and
computes its body digest; the NE engine (Python, or Go / C later) recomputes it
from the same logical value and must get the identical digest, or the
stage-first idempotency guarantee is void.

Rules (RFC 8785, matching the Swift encoder exactly):

* Object keys sorted by UTF-8 **byte** order.
* No insignificant whitespace.
* Escape only ``\"``, ``\\``, and control code points U+0000..U+001F.
  Every other code point -- including non-ASCII -- is emitted as raw UTF-8
  (this is the JCS difference from ``json.dumps`` with ``ensure_ascii=True``).
* Numbers: integers in decimal with no leading zeros; no float special values
  (the IDL carries integers / decimal-string counters only).

There is no RNS / LXMF import here on purpose -- this layer must build and
test on any platform with a plain CPython, so cross-language parity can be
proven independently of the Reticulum runtime.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

__all__ = ["canonical_bytes", "canonical_json", "sha256_hex", "digest_hex"]

# U+0000..U+001F -> the shortest legal JSON escape, per RFC 8785.
_CONTROL_ESCAPES = {
    0x08: "\\b",
    0x09: "\\t",
    0x0A: "\\n",
    0x0C: "\\f",
    0x0D: "\\r",
}


def _encode_string(value: str) -> bytes:
    """Emit a JSON string literal per RFC 8785: escape only ``"\\`` + control
    U+0000..U+001F, everything else as raw UTF-8 bytes."""
    out = bytearray()
    out.append(0x22)  # opening quote
    for ch in value:
        cp = ord(ch)
        if ch == '"':
            out += b'\\"'
        elif ch == "\\":
            out += b"\\\\"
        elif cp < 0x20:
            esc = _CONTROL_ESCAPES.get(cp)
            if esc is not None:
                out += esc.encode("ascii")
            else:
                out += ("\\u%04x" % cp).encode("ascii")
        else:
            out += ch.encode("utf-8")
    out.append(0x22)  # closing quote
    return bytes(out)


def _encode_number(value: int) -> bytes:
    if not isinstance(value, int) or isinstance(value, bool):
        raise TypeError("numbers must be integers, got %r" % (value,))
    return str(value).encode("ascii")


def _encode(value: Any) -> bytes:
    """Recursively encode a Python value (dict/list/str/int/None/bool) to its
    canonical UTF-8 form. Keys sorted by UTF-8 byte order at every level."""
    if value is None:
        return b"null"
    if value is True:
        return b"true"
    if value is False:
        return b"false"
    if isinstance(value, int):
        return _encode_number(value)
    if isinstance(value, str):
        return _encode_string(value)
    if isinstance(value, list):
        return b"[" + b",".join(_encode(item) for item in value) + b"]"
    if isinstance(value, dict):
        # Sort by the UTF-8 byte representation of the key -- the exact rule the
        # Swift encoder uses (byte order == UTF-16 code-unit order for valid
        # JSON object keys).
        ordered = sorted(value.items(), key=lambda kv: kv[0].encode("utf-8"))
        parts = [b",".join(
            _encode_string(k) + b":" + _encode(v) for k, v in ordered
        )]
        return b"{" + parts[0] + b"}"
    raise TypeError("not a canonical JSON value: %r" % (value,))


def canonical_bytes(value: Any) -> bytes:
    """Return the RFC 8785 canonical UTF-8 bytes of ``value``."""
    return _encode(value)


def canonical_json(value: Any) -> str:
    """Return the RFC 8785 canonical JSON of ``value`` as a str (UTF-8 decoded)."""
    return _encode(value).decode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_hex(value: Any) -> str:
    """Return the SHA-256 hex digest of the canonical bytes of ``value``.

    This is the ``bodyDigest`` the Swift app computes when it stages an intent
    and the NE engine must independently reproduce from the same logical value.
    """
    return sha256_hex(canonical_bytes(value))
