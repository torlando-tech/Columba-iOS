"""Control-channel codec tests (pure Python, no RNS).

Locks the Python ``control`` module to the same wire contract the Swift
``ColumbaNode/Control`` layer implements:

* framing (``[0xF5 0x02]`` + payload), the hard 64 KiB cap, and the hard
  unknown-version error (a frame ``0xF5 <not 0x02>`` must NOT fall through);
* byte-for-byte parity with the Swift side for the contract's reference
  ``helloRequest`` / ``admitRequest`` (same canonical JSON the Swift encoder
  produces, so the Python-encoded envelope == the Swift-encoded envelope).

Runs with the system interpreter:

    python3 -m unittest engine.columba_node.tests.test_control -v
"""

from __future__ import annotations

import json
import unittest

from engine.columba_node.canonical import canonical_bytes
from engine.columba_node.control import (
    MAX_ENVELOPE_BYTES,
    ControlChannelError,
    MAGIC,
    Request,
    Reply,
    decode_payload,
    encode_envelope,
    framing_error,
)


class FramingTests(unittest.TestCase):
    def test_encode_then_decode_roundtrip(self):
        payload = canonical_bytes({"requestID": "x", "body": {"tag": "hello", "value": {}}})
        env = encode_envelope(payload)
        self.assertEqual(env[:2], MAGIC)
        self.assertEqual(decode_payload(env), payload)

    def test_hard_cap_includes_magic(self):
        # Payload that pushes the envelope (magic + payload) over 64 KiB.
        too_big = b"\x7b" * (MAX_ENVELOPE_BYTES - len(MAGIC) + 1)
        with self.assertRaises(ControlChannelError) as ctx:
            encode_envelope(too_big)
        self.assertEqual(ctx.exception.kind, "envelopeTooLarge")
        # Exactly at the cap is allowed.
        ok = b"\x7b" * (MAX_ENVELOPE_BYTES - len(MAGIC))
        self.assertEqual(encode_envelope(ok), MAGIC + ok)

    def test_bad_magic_rejected(self):
        with self.assertRaises(ControlChannelError) as ctx:
            decode_payload(b"\x00\x02abc")
        self.assertEqual(ctx.exception.kind, "badMagic")

    def test_unknown_version_is_hard_error(self):
        # 0xF5 but a version other than 0x02 -> hard protocol error, never a
        # legacy fall-through.
        with self.assertRaises(ControlChannelError) as ctx:
            decode_payload(b"\xF5\x01abc")
        self.assertEqual(ctx.exception.kind, "badVersion")

    def test_truncated_rejected(self):
        with self.assertRaises(ControlChannelError):
            decode_payload(b"\xF5")


class RequestWireParityTests(unittest.TestCase):
    def test_hello_request_matches_contract_reference(self):
        """The Python hello request must canonicalize to the EXACT bytes the
        Swift encoder produces for the contract's helloRequest (examples.json)."""
        req = Request.hello(
            request_id="55555555-5555-4555-8555-555555555555",
            versions=[{"major": 1, "minor": 0}],
            schema_min=1,
            schema_max=1,
        )
        got = req.to_wire()
        expected = {
            "requestID": "55555555-5555-4555-8555-555555555555",
            "body": {
                "tag": "hello",
                "value": {
                    "versions": [{"major": 1, "minor": 0}],
                    "schemaMin": 1,
                    "schemaMax": 1,
                },
            },
        }
        self.assertEqual(canonical_bytes(got), canonical_bytes(expected))
        # And it round-trips back through the decoder.
        decoded = Request.decode(req.encode())
        self.assertEqual(decoded.request_id, req.request_id)
        self.assertEqual(decoded.body_tag, "hello")
        self.assertEqual(decoded.value, expected["body"]["value"])

    def test_admit_request_carries_only_command_id(self):
        """admit must NOT carry the staged body inline - only the commandID
        (contract 3.3, 6). This is the property the whole stage-first design
        depends on."""
        session = Request.session(
            {"major": 1, "minor": 0},
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        )
        req = Request.admit(
            request_id="66666666-6666-4666-8666-666666666666",
            session=session,
            command_id="44444444-4444-4444-8444-444444444444",
        )
        wire = req.to_wire()
        # session present, commandID present, and NO body field.
        self.assertEqual(wire["body"]["value"]["commandID"],
                         "44444444-4444-4444-8444-444444444444")
        self.assertEqual(wire["body"]["value"]["session"], session)
        self.assertNotIn("body", wire["body"]["value"])
        # session_ctx helper returns the session for a non-hello request.
        self.assertEqual(req.session_ctx(), session)

    def test_session_ctx_is_none_for_hello(self):
        req = Request.hello("r", [], 1, 1)
        self.assertIsNone(req.session_ctx())


class ReplyWireParityTests(unittest.TestCase):
    def test_admission_reply_matches_contract_reference(self):
        """The Python admission reply must canonicalize to the EXACT bytes the
        Swift encoder produces for the contract's acceptedReply (examples.json)."""
        record = {
            "commandID": "44444444-4444-4444-8444-444444444444",
            "bodyDigest": "952cb4131c408b2831f2b2188ffd3300df2f50ec1a49c28af6b4bdeea90c86ec",
            "disposition": "accepted",
            "acceptedAt": 1790000000500,
            "operationID": "44444444-4444-4444-8444-444444444444",
            "rejection": None,
            "committedThrough": {
                "storeEpoch": "11111111-1111-4111-8111-111111111111",
                "sequence": "42",
            },
        }
        reply = Reply.admission_reply(
            request_id="66666666-6666-4666-8666-666666666666",
            command_record=record,
            store_epoch="11111111-1111-4111-8111-111111111111",
            boot_id="22222222-2222-4222-8222-222222222222",
        )
        expected = {
            "requestID": "66666666-6666-4666-8666-666666666666",
            "storeEpoch": "11111111-1111-4111-8111-111111111111",
            "bootID": "22222222-2222-4222-8222-222222222222",
            "result": {
                "tag": "success",
                "value": {"tag": "admission", "value": record},
            },
        }
        self.assertEqual(canonical_bytes(reply.to_wire()), canonical_bytes(expected))
        self.assertTrue(reply.ok)
        # round-trip through the framed bytes.
        decoded = Reply.decode(reply.encode())
        self.assertTrue(decoded.ok)
        self.assertEqual(decoded.result["value"]["value"]["bodyDigest"],
                         "952cb4131c408b2831f2b2188ffd3300df2f50ec1a49c28af6b4bdeea90c86ec")

    def test_failure_reply(self):
        reply = Reply.failure(
            request_id="r",
            error={"code": "capabilityUnsupported", "field": "op",
                   "retry": "retryableAfterStateChange"},
            store_epoch="11111111-1111-4111-8111-111111111111",
        )
        self.assertFalse(reply.ok)
        err = reply.result.get("value")
        self.assertEqual(err["code"], "capabilityUnsupported")
        decoded = Reply.decode(reply.encode())
        self.assertFalse(decoded.ok)
        derr = decoded.result.get("value")
        self.assertEqual(derr["field"], "op")


if __name__ == "__main__":
    unittest.main()
