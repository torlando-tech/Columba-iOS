"""Cross-language canonical-digest parity tests (pure Python, no RNS).

These lock the Python engine's canonical encoder to the SAME reference vector
the Swift ``ColumbaNode`` backbone locks to (``.scratch/ne-node-contract/docs/
contracts/examples.json``). If the Python digest ever drifts from the Swift
digest, this fails - which is exactly the drift that would silently break the
stage-first idempotency guarantee across the app<->NE seam.

Runs with the system interpreter (``python3``), no CPython-embed, no RNS:

    python3 -m unittest engine.columba_node.tests.test_canonical -v
"""

from __future__ import annotations

import json
import unittest

from engine.columba_node.canonical import (
    canonical_bytes,
    canonical_json,
    digest_hex,
)

# The exact reference vector from .scratch/ne-node-contract/docs/contracts/
# examples.json, hard-coded (as the Swift test does) because .scratch/ is
# gitignored and so is unavailable on a fresh clone / in CI. The Swift
# ColumbaNode CanonicalDigestTests asserts the SAME canonical bytes + digest,
# so green on both sides proves the two languages agree on the wire form.
EXPECTED_CANONICAL = (
    '{"afterCommandID":null,"body":{"tag":"submitMessage","value":'
    '{"deadline":1790086400000,"delivery":{"allowPropagationFallback":false,'
    '"maxAttempts":3,"preferred":"automatic","stampBudgetMs":5000},'
    '"destination":"0123456789abcdef0123456789abcdef",'
    '"payload":{"tag":"chat","value":{"appearance":null,"attachments":[],'
    '"content":{"tag":"inline","value":"Hello from Columba"},'
    '"extensions":null,"reply":null,"title":{"tag":"inline","value":""}}},'
    '"scope":{"identityID":"33333333-3333-4333-8333-333333333333"}}},'
    '"commandID":"44444444-4444-4444-8444-444444444444",'
    '"createdAt":1790000000000,"expiresAt":null,'
    '"storeEpoch":"11111111-1111-4111-8111-111111111111"}'
)
EXPECTED_DIGEST = "952cb4131c408b2831f2b2188ffd3300df2f50ec1a49c28af6b4bdeea90c86ec"

# The logical staged intent (same shape/keys as the canonical string above),
# re-ordered / re-keyed on purpose so the test exercises key-sorting rather
# than accidentally matching by literal string.
STAGED_INTENT = {
    "commandID": "44444444-4444-4444-8444-444444444444",
    "storeEpoch": "11111111-1111-4111-8111-111111111111",
    "createdAt": 1790000000000,
    "expiresAt": None,
    "afterCommandID": None,
    "body": {
        "tag": "submitMessage",
        "value": {
            "scope": {"identityID": "33333333-3333-4333-8333-333333333333"},
            "destination": "0123456789abcdef0123456789abcdef",
            "payload": {
                "tag": "chat",
                "value": {
                    "title": {"tag": "inline", "value": ""},
                    "content": {"tag": "inline", "value": "Hello from Columba"},
                    "attachments": [],
                    "reply": None,
                    "appearance": None,
                    "extensions": None,
                },
            },
            "delivery": {
                "preferred": "automatic",
                "allowPropagationFallback": False,
                "maxAttempts": 3,
                "stampBudgetMs": 5000,
            },
            "deadline": 1790086400000,
        },
    },
}


class CanonicalParityTests(unittest.TestCase):
    def test_matches_contract_reference_vector(self):
        """Python canonical bytes == the contract's canonicalIntentUTF8, and the
        SHA-256 == bodySHA256. The Swift side asserts the same two values
        byte-for-byte, so green on both means the languages agree on the wire."""
        self.assertEqual(canonical_json(STAGED_INTENT), EXPECTED_CANONICAL,
                         "Python canonical JSON drifted from the contract "
                         "reference vector (and the Swift encoder).")
        self.assertEqual(digest_hex(STAGED_INTENT), EXPECTED_DIGEST,
                         "Python bodySHA256 drifted from the contract vector.")

    def test_canonical_is_valid_json(self):
        """The canonical form is a byte ordering, not a different value: it
        must json.loads back to an object equal to the logical intent."""
        self.assertEqual(json.loads(canonical_json(STAGED_INTENT)), STAGED_INTENT)

    def test_key_order_is_byte_order(self):
        """Insertion order must not leak into the canonical form: two dicts
        with the same entries in different insertion orders canonicalize to
        the identical bytes (and digest)."""
        a = {"b": 1, "A": 2, "aB": 3}
        b = {"aB": 3, "A": 2, "b": 1}
        self.assertEqual(canonical_bytes(a), canonical_bytes(b))
        self.assertEqual(digest_hex(a), digest_hex(b))

    def test_nonascii_is_raw_utf8(self):
        """JCS emits non-ASCII as raw UTF-8, NOT \\uXXXX. A value with a
        non-ASCII string must not contain a backslash-u escape for it."""
        v = {"s": "héllo→"}
        blob = canonical_bytes(v)
        # The é and → must be present as their UTF-8 bytes, not escaped.
        self.assertIn("héllo→".encode("utf-8"), blob)
        self.assertNotIn(b"\\u", blob)
        # Round-trips back to the same value.
        self.assertEqual(json.loads(blob.decode("utf-8")), v)

    def test_control_chars_escaped(self):
        v = {"s": "a\tb\nc"}
        blob = canonical_json(v)
        # \t and \n use the short escapes; no raw control bytes remain.
        self.assertIn("\\t", blob)
        self.assertIn("\\n", blob)
        for cp in range(0x20):
            self.assertNotIn(chr(cp), blob)

    def test_empty_and_null(self):
        self.assertEqual(canonical_bytes({}), b"{}")
        self.assertEqual(canonical_bytes([]), b"[]")
        self.assertEqual(canonical_bytes(None), b"null")
        self.assertEqual(canonical_bytes(True), b"true")
        self.assertEqual(canonical_bytes(0), b"0")


if __name__ == "__main__":
    unittest.main()
