# Model B - Experimental Background LXMF Delivery

> **Status:** Experimental/deferred app flavor. Model B is built by the
> `ColumbaModelBApp` target and `Columba-ModelB` scheme. It is not included in
> the shipping `ColumbaApp` artifact or the standard `Columba` scheme.
>
> The on-device results dated 2026-06-02 below are historical evidence for the
> topology, not verification of the current target split. See
> [Current verification](#current-verification) for the checks required now.

Model B explores delivery of an LXMF message and local notification while its app is backgrounded, suspended, or locked, without APNS. A Network Extension runs the Reticulum/LXMF node and completes proof, decryption, persistence, and notification rather than only sniffing traffic.

The shipping Python flavor does not make this guarantee. Its default Internet TCP delivery is foreground/opportunistic.

---

## Why this shape ("Model B")

A suspended iOS app cannot be woken to finish arbitrary network work, so background delivery requires a separately scheduled process that owns the messaging endpoint and completes delivery. In this experiment, `NEPacketTunnelProvider` is that process: iOS schedules it for the active VPN/tunnel independently of the app lifecycle.

**Model B makes the extension the canonical, SOLE node.** It owns the single `lxmf.delivery` destination and terminates every transfer. The app is a UI satellite that has no RNS runtime of its own and reaches the node only over the App-Group IPC seam. The rejected Model A topology let the app own the node while the extension sniffed and handed off; two processes contending for one destination creates path-flap, link double-response, and cross-process receive-dedup races. Model B instead has one delivery node and one deduplication authority.

## Engine

The node is **Python RNS** (`app/rns_bridge.py`), embedded and run in-process inside the extension. It is the single Reticulum runtime in the build - there is no ReticulumSwift, no `LXMFSwift`/`LXMFDatabase`, and no `NEReticulumNode` in the NE. The Swift extension code is a thin host:

- `NEPythonRNS` (`Sources/ColumbaNetworkExtension/`) drives the embedded CPython runtime and calls the `rns_bridge` module over the C-API (start/stop, `drain_events`, `send_opportunistic`, link ops, BLE, RNode).
- `PacketTunnelProvider.dispatchPython` decodes a `ProxyRequest` from the app and maps each op onto an `NEPythonRNS` call, then maps the Python JSON result back onto a `ProxyResponse`.

The extension owns the transport in-process, so inbound delivery, announces, BLE, and RNode all run inside the NE without any hand-off to the app.

## Flavor boundary

Model B is selected only by compiling the explicit `ColumbaModelBApp` target with `COLUMBA_RUNTIME_MODEL_B`. Build flavor is not selected by user defaults or settings. `BackendPreference.modelB`, persisted `useSwiftBackend`, the `Debug-Swift`/`Release-Swift` configurations, and the `Columba-Swift` scheme are retired as architecture selectors. `COLUMBA_BACKEND_SWIFT` remains defined on Model B as a temporary compatibility condition for transport settings; it does not select the flavor.

The experimental app owns:

- `ProxyRnsBackend` and the Model B host/proxy lifecycle;
- App Group control IPC, outbox, and the event stream;
- background-delivery onboarding and gate behavior;
- VPN permission, tunnel install/start/wait, status/settings UI, and extension diagnostics;
- a target dependency plus signed embed for `ColumbaNetworkExtension`.

It contains no `Python.xcframework`, Python-only bridge/runtime/backend sources, Python `app/` resource tree, wheels, standard-library packaging, or Python install/embed phases (the Python runtime and `rns_bridge.py` live in the EXTENSION, not the app).

The shipping `ColumbaApp` has the reciprocal ownership: embedded Python RNS/LXMF and its packaging (run in-process in the app, Model A), with no Network Extension dependency/embed, packet-tunnel entitlement, or Model B lifecycle/UI/proxy behavior.

---

## Runtime topology (two processes)

```
                 ┌──────────────────────────── iPhone ────────────────────────────┐
  internet/LAN   │  NE process (PacketTunnelProvider + NEPythonRNS) - THE node     │
  (TCP relay) ───┼─▶   • embedded CPython + rns_bridge.py = the single RNS runtime  │
  BLE / RNode ───┼─▶   • shared identity (keychain access group)                   │
  (radio peers)  │     • lxmf.delivery destination (the one true endpoint)         │
                 │     • TCP relay interface + BLE + RNode radios (in-NE)          │
                 │     • prove / link / resource / decrypt - ALL here              │
                 │     • writes plaintext -▶ shared App-Group GRDB store           │
                 │     • durable event inbox (cursor-acked) + newMessage ping      │
                 │                                                                │
                 │  App process (ColumbaModelBApp) - UI only, NO RNS runtime       │
                 └─▶   • ProxyRnsBackend: send/announce/status/drain -▶ NE via IPC  │
                       • UI reads shared GRDB state + the drained event stream      │
                 └──────────────────────────────────────────────────────────────────┘
```

ONE destination on the NE. The app is a thin client that marshals node-owning operations over `NETunnelProviderSession.sendProviderMessage` and consumes the events the NE drains for it.

### Who owns what

| Concern | Owner | Notes |
|---|---|---|
| `lxmf.delivery` destination + identity | **NE** | Identity loaded from the shared keychain access group; the node is Python RNS in-process |
| RNS/LXMF runtime | **NE** | `rns_bridge.py` in embedded CPython; the only RNS runtime in the build |
| TCP relay / BLE / RNode radios | **NE** | The radios run in-NE; the app pumps no frames |
| Inbound prove/decrypt/persist/notify | **NE** | Python delivery callback persists to the shared GRDB store and posts the ping |
| Self-announce of the delivery destination | **NE** | The app cannot announce while suspended |
| Durable event inbox + cursor | **NE** | Bounded read + explicit ack (Contract §5); survives app suspension/death |
| Offline-outbound replay | **NE** | `replayOutbox()` on node start; stable `sendId` dedup prevents double-send |
| Send / announce / status / drain requests | **App -> NE** | `ProxyRnsBackend` over `ProxyIPC` |
| UI and shared-store operations | **App** | Reads messages and performs conversation/message UI mutations in the shared GRDB store |

## Inbound delivery flow

1. A sender resolves a path to `lxmf.delivery`, learned from the NE's announce, and opens an RNS link or sends opportunistically.
2. Frames arrive at the NE over its TCP relay or BLE/RNode radio - the radios run in-NE, so there is no app-side radio relay.
3. `rns_bridge.py` handles the link/resource in-process: validates the signature, dedups, and decrypts; the Python delivery callback persists the plaintext row directly into the shared App-Group GRDB store.
4. The NE posts a local `UNUserNotification` and the `network.columba.newMessage` Darwin notification for foreground refresh. Non-message events (state, delivery proofs, link, announces) are appended to the durable inbox and drained over IPC.
5. The sender receives an RNS delivery proof.
6. On next open, the app reads the persisted message from shared GRDB without re-fetching it.

This path runs entirely in the extension while `ColumbaModelBApp` is suspended or locked.

## Outbound/send flow

1. The app calls `ProxyRnsBackend.sendLxmfMessage(...)` with one app-assigned stable `sendId` per logical send (architecture review P1 #6).
2. The proxy marshals a `ProxyRequest.lxmfSend` envelope (carrying the `sendId`) over IPC to the extension.
3. `NEPythonRNS.lxmfSend` dedups on the `sendId` via the durable `SentIdStore` (a send whose `sendId` is already recorded is skipped, not double-sent), then `rns_bridge.send_opportunistic` builds and sends the LXMF message in-NE. On a committed result the `sendId` is recorded.
4. Outbound state returns through the GRDB `messages.state` column and the `network.columba.newMessage` Darwin notification.
5. If the extension is unavailable, the app stores the request (with the same `sendId`) in the App-Group outbox; `NEPythonRNS.replayOutbox()` drains it on the next node start and replays each entry through the same deduped send path (architecture review P1 #3). A lost live reply plus replay therefore cannot double-send.

## Announce flow

The extension announces its own `lxmf.delivery` destination:

- on node start, after the relay reports connected;
- on relay reconnect, so a restarted relay promptly relearns the path; and
- periodically at the configured interval.

The app's announce action routes through `ProxyRnsBackend.announce` -> IPC -> `NEPythonRNS` -> `rns_bridge`.

---

## IPC and event bridge

- **Control IPC** (`Sources/Shared/ProxyIPC.swift`) defines Foundation-only `ProxyRequest`/`ProxyResponse` envelopes. `ProxyRnsBackend` (`Sources/RNSBackendProxy/`) sends them with `NETunnelProviderSession.sendProviderMessage`; `PacketTunnelProvider.dispatchPython` decodes and dispatches to `NEPythonRNS`. Keeping this seam Foundation-only prevents any RNS/LXMF type from crossing it - node-owning operations cross as serialized scalars/`Data`.
- **Event bridge:** the NE's `drain_events` is a bounded, NON-destructive read of the durable inbox (each row carries its `seq`). The app re-emits each drained event as a `BackendEvent` on its stream, then advances the cursor via `ProxyRequest.ackInbox(maxSeq:)`; the NE deletes only rows at or below the acked cursor (Contract §5). Unacked rows survive a lost drain reply or app termination and are re-returned on the next drain (at-least-once delivery; announce dedup and the UI's message-hash idempotency make re-delivery idempotent).

## Shared state

- **Identity:** The app creates the identity in the shared keychain access group; the extension reads it. `AfterFirstUnlockThisDeviceOnly` accessibility permits extension access while locked after first unlock. App Group defaults carry the resolved group name for locked-start cases.
- **Message store:** The Python node's inbound rows are written by `rns_bridge` into the shared App-Group GRDB store (WAL + busy_timeout for cross-process access); the app's `ModelBInboundReplay` scans it on the Darwin `newMessage` ping (immediately while open) and on start (catch-up). Outbound delivery-state updates are also owned by the NE.

## Load-bearing invariants

1. **Single node, single runtime:** The extension alone owns `lxmf.delivery`, and it is the ONLY Reticulum runtime in the build (Python in-NE). `ColumbaModelBApp` has no RNS runtime and does not start a competing destination-owning backend, TCP interface, or radio.
2. **Single delivery authority:** The extension handles inbound delivery persistence and app-composed outbound send/persist work. The app may still write UI-managed conversation and message state, but it does not run a second node or independently terminate inbound transfers.
3. **Durable, cursor-acked events:** The durable event inbox advances only by explicit ack/cursor, so a lost reply or app death cannot silently drop delivery-state updates or announces (at-least-once, idempotent on re-delivery).
4. **Stable submission identity:** Outbound sends carry an app-assigned `sendId`; the NE dedups on it so a lost live reply plus outbox replay cannot double-send.
5. **Stable node identity:** Shared identity plus shared store recreates the same node after extension restart; on-demand connection can relaunch it.
6. **Foundation-only seam:** Files crossing the app/NE IPC seam import Foundation only; no RNS/LXMF type crosses it.

---

## Build and packaging

Use the explicit experimental scheme:

```sh
xcodebuild -project Columba.xcodeproj \
  -scheme Columba-ModelB \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

`Columba-ModelB` is the canonical workflow. Its Build action includes `ColumbaModelBApp` and `ColumbaNetworkExtension`, and its Test action includes `ColumbaModelBAppTests`; use `build-for-testing` when all three must be compiled. Do not instruct users to build the extension separately as the normal path. Physical-device verification requires signing and provisioning for both the app and extension, including Network Extension and App Group capabilities.

`support/isolate-modelb-targets.rb` is the authoritative target/scheme reconciler. `support/configure-xcodeproj.rb` and `support/add-swift-backend-config.rb` are retired and fail closed. `support/embed-ne.rb` delegates to the authoritative reconciler, while `support/add-ne-backend-deps.rb` remains narrowly scoped to extension package dependencies.

A release/build-artifact review should confirm both directions of isolation at a high level: shipping contains no extension or Model B crossover, and Model B contains the signed extension (with its embedded Python runtime + `rns_bridge.py`) but no in-app Python packaging output. These checks belong in build verification; this document does not define CI implementation.

---

## Historical on-device evidence (2026-06-02, iPhone 14)

The following evidence predates the explicit app-target split AND the migration of the node engine from ReticulumSwift to in-NE Python RNS, and must not be presented as current verification:

- **Announce-out:** The extension's `lxmf.delivery` announce was cryptographically validated against RNS `validate_announce`, and the relay installed a path.
- **Inbound LXMF delivery:** A real desktop-peer DIRECT message reached `DELIVERED` at the sender. Extension diagnostics reported `inbound message persisted`; the node validated and stored it, and the delivery delegate posted the notification.

The June 2 run did not exercise locked-device delivery or the app-side radio relay path (the radios are now in-NE, so that path no longer exists).

### Historical reproduction outline

1. Confirm `rnpath <delivery-dest-hash>` resolves through the relay.
2. Send a DIRECT LXMF message and require sender state `DELIVERED`.
3. Retrieve the extension's `ext-diag.log` from the app data container and confirm `inbound message persisted`.

References named in the original engineering record include `reference_mac_relay_wedge_diagnostic.md` and `track_modelb_tcp_egress_announce_2026-06-02.md`; they are external working notes, not repository documentation links.

## Current verification

Current Model B changes require fresh evidence from the explicit flavor:

1. Build/test the `Columba-ModelB` scheme as a unit so the app, Model B tests, and extension are all covered.
2. Inspect products to confirm the extension is signed and embedded only in `ColumbaModelBApp`, with the embedded Python runtime + `rns_bridge.py`, Model B capabilities present, and no in-app Python packaging output.
3. Inspect the shipping `Columba` product separately to confirm no extension, packet-tunnel entitlement, Model B sources/resources, or Model B runtime behavior is present.
4. On a signed physical device, complete onboarding and its background-delivery gate, grant VPN permission, install/start/wait for the tunnel, and verify status/settings and extension diagnostics.
5. Repeat announce, inbound proof/persist/notification, outbound, restart/outbox-replay, locked-device, and the drain/ack event-bridge scenarios. Record device/OS, commit, signing/capability state, and diagnostics.

Until those checks are rerun on the current target graph and engine, the June 2 results remain useful historical evidence, not a claim that the experimental flavor or shipping app currently guarantees background delivery.
