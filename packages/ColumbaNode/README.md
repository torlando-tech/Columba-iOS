# ColumbaNode

The engine-agnostic backbone for the node-service v1 contract
(`.scratch/ne-node-contract`). Both the app (typed facade / shared-store reader)
and the Network Extension (node owner / engine host) link this one package, so
the seam is a single source of truth.

The design goal: the contract's IDL is language-neutral, and the Reticulum
implementation is swappable. The store, command ledger, canonical digest, and
control framing are all shared and engine-independent; only the engine behind
`NodeEngine` changes. In order of preference the engines are:
1. Python RNS (official reference; first engine - embedded CPython in the NE)
2. Reticulum-Go (https://github.com/Quad4-Software/Reticulum-Go)
3. microReticulum (the C++ engine the existing Model B NE already runs)

## Layers

- `Types` - distinct ID/hash/counter/Instant wrappers + `Feature`/`Availability`
  enums (contract 2).
- `Support` - RFC 8785 canonical JSON encoder, pure-Swift SHA-256, `JsonValue`.
- `Command` - the command vocabulary, `Intent` (canonical digest = idempotency
  key), `NodeError`/`ErrorCode`, `CommandRecord`/`LocalReceipt`.
- `Store` - the one SQLite store (WAL/FULL, typed `SQLValue` params, explicit
  NULL) with durable stage-first admission, the command ledger (idempotent
  re-admit, body-conflict detection, ledger-first over a changed policy),
  `LocalSequence` reservation, and the node change index (contract 3, 5).
- `Control` - the bounded app<->NE control channel: `[0xF5, 0x02]` framing, hard
  64 KiB envelope cap, `hello`/`admit`/`query`/`act` request+reply codec
  (contract 6). The complete command body is never inline - `admit` carries only
  the commandID, resolved against the shared store's ledger (contract 3.3).
- `Engine` - the `NodeEngine` adapter seam (contract 15, ADR 0001). A node owner
  (NE) drives one engine; the facade/store/control-channel never touch the
  engine directly. `StubEngine` fails closed as the default before a real engine
  is installed.

## Building / testing

```
cd packages/ColumbaNode
swift build
swift test
```

20 unit tests run on Linux: the canonical digest is locked to the contract's
`examples.json` reference vector byte-for-byte; the store's stage/admit/ledger
semantics are covered; the control channel's framing, 64 KiB cap,
unknown-version hard failure, and hello/admit/query round-trips are covered,
including the stage-in-store -> admit-over-channel -> resolve-from-ledger flow.

## Status / next

This package is the proven, engine-agnostic core. It is NOT yet linked into the
Xcode app/NE targets. The next increment wires `ColumbaNode` into the existing
`ColumbaNetworkExtension` (reused, cleaned up): a real `NodeEngine` conformance
that runs embedded CPython + Python RNS, the NE-side control-channel handler
(over the existing `0xF5` IPC socket), and the app-side typed facade that
stages intents and reads the shared store. The NE + embedded-CPython + RNS
integration is Mac-only (Network Extension + CPython + iOS signing), so it is
built and tested on the Mac at 10.0.0.145.
