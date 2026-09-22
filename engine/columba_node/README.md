# engine/columba_node - the Python half of the node-service seam

The engine-agnostic, language-agnostic core that a Reticulum implementation
runs against when it is the **node owner** side of the contract
(`.scratch/ne-node-contract`). This is the Python RNS engine first; Reticulum-Go
and microReticulum drop in behind the same seam later (the Swift side is
`Sources/ColumbaNode/`, the `NodeEngine` protocol being the shared abstraction).

## Why two halves of one contract

The node-service contract says the app (Swift) and the NE (engine) must agree on
one canonical byte form, or the stage-first idempotency guarantee is void: a
lost IPC reply could otherwise mint a second logical send. So there are exactly
two encoders and they are the same algorithm:

* Swift: `Sources/ColumbaNode/Support/JsonValue.swift` (RFC 8785) + `SHA256.swift`
* Python: `engine/columba_node/canonical.py` (RFC 8785) + `hashlib.sha256`

Both are locked to the SAME contract reference vector
(`examples.json` -> `canonicalIntentUTF8` + `bodySHA256`). Green on both sides
means the two languages produce identical digests for the same logical intent.
That parity is what makes the IDL language-agnostic: swap the engine and the
wire bytes do not change.

The same holds for the control-channel framing + `Request`/`Reply` shapes:
`engine/columba_node/control.py` mirrors `Sources/ColumbaNode/Control`
field-for-field, so a Swift-encoded frame decodes in Python and vice-versa.

## Modules

* `canonical.py` - canonical JSON (RFC 8785) + SHA-256. Pure Python, no RNS.
* `control.py` - `[0xF5 0x02]` framing (hard 64 KiB cap, unknown-version hard
  error) + `Request`/`Reply` wire codec (hello / admit / query / act). Pure
  Python, no RNS. The complete command body is NEVER sent inline - `admit`
  carries only the commandID; the body is already staged in the shared store.

The RNS-specific engine (boots Python RNS, maps commands to `rns_bridge`
operations) sits above these and is the Mac-gated part (it needs the RNS wheel).

## Tests (pure Python, run on the Linux controller or anywhere)

```
python3 -m unittest discover -s engine/columba_node/tests -v
```

`test_canonical.py` proves Python reproduces the contract reference vector
byte-for-byte (the cross-language parity keystone). `test_control.py` proves the
framing cap + version hard-fail and that hello/admit replies canonicalize to the
exact bytes the Swift encoder produces.
