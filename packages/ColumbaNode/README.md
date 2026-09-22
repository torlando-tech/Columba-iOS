# ColumbaNode

The engine-agnostic backbone for the node-service v1 contract
(`.scratch/ne-node-contract`). Both the app (typed facade / shared-store reader)
and the Network Extension (node owner / engine adapter) link this package.

It deliberately contains **no protocol engine**. Python RNS (and later
Reticulum-Go / microReticulum) plugs in behind the engine-adapter seam (contract
§15). This package defines the durable, canonical contract only:

- the IDL common type system (distinct UUID / hex / counter wrappers)
- RFC 8785 canonical encoding + SHA-256 (the ONE place command digests are
  produced — contract §3)
- the durable command vocabulary (Intent / Command / receipts / records)
- the shared SQLite store + command ledger + stage-first admission rules

Pure Swift + system `sqlite3`, so it builds and tests on Linux and Darwin.

## Layout

```
Sources/ColumbaNode/
  Support/     JsonValue (RFC 8785), SHA256, JsonEncodable
  Types/       the IDL common type system
  Command/     Intent, Command, receipts, NodeError
  Store/       SQLite store, command ledger, admission   (in progress)
```

## Build / test (Linux or Darwin)

```sh
cd packages/ColumbaNode
swift build
swift test
```

`CanonicalDigestTests` locks the canonical encoder to the contract's reference
vector (`docs/contracts/examples.json`): the same staged `submitMessage` intent
must hash to `952cb4…c86ec` in Swift exactly as the reference does.
