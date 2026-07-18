# Model B — Experimental Background LXMF Delivery

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

**Model B makes the extension the canonical node.** It owns the single `lxmf.delivery` destination and terminates every transfer. The app is a transport/UI satellite. The rejected Model A topology let the app own the node while the extension sniffed and handed off; two processes contending for one destination creates path-flap, link double-response, and cross-process receive-dedup races. Model B instead has one delivery node and one deduplication authority.

## Flavor boundary

Model B is selected only by compiling the explicit `ColumbaModelBApp` target with `COLUMBA_RUNTIME_MODEL_B`. Build flavor is not selected by user defaults or settings. `BackendPreference.modelB`, persisted `useSwiftBackend`, the `Debug-Swift`/`Release-Swift` configurations, and the `Columba-Swift` scheme are retired as architecture selectors. `COLUMBA_BACKEND_SWIFT` remains defined on Model B as a temporary compatibility condition for transport settings; it does not select the flavor.

The experimental app owns:

- `ProxyRnsBackend` and the Model B host/proxy lifecycle;
- App Group control IPC, frame bridges, outbox, and BLE/RNode seams;
- background-delivery onboarding and gate behavior;
- VPN permission, tunnel install/start/wait, status/settings UI, and extension diagnostics;
- direct ReticulumSwift linkage and a target dependency plus signed embed for `ColumbaNetworkExtension`.

It contains no `Python.xcframework`, Python-only bridge/runtime/backend/model sources, Python `app/` resource tree, wheels or standard-library packaging, bridging header, or Python install/embed phases.

The shipping `ColumbaApp` has the reciprocal ownership: embedded Python RNS/LXMF and its packaging, with no Network Extension dependency/embed, packet-tunnel entitlement, or Model B lifecycle/UI/proxy behavior. Shipping retains a direct ReticulumSwift link only because shared public `MessageRepository`/`LXMFSwift` signatures expose ReticulumSwift types, not because it runs Model B.

---

## Runtime topology (two processes)

```
                 ┌──────────────────────── iPhone ────────────────────────┐
  TCP relay ─────┼─▶ NE process (NEReticulumNode) — THE node               │
 (internet/LAN)  │     • shared identity (keychain access group)           │
                 │     • ReticulumSwift transport + LXMFSwift LXMRouter     │
                 │     • lxmf.delivery destination (the one true endpoint)  │
                 │     • owns the TCP relay interface (its own NWConnection) │
                 │     • AppGroupBridgeInterface ◀──────────────────────┐   │
                 │     • prove / link / resource / decrypt — ALL here    │   │
                 │     • writes plaintext ─▶ shared App-Group GRDB store  │   │
                 │     • posts user notification + newMessage Darwin signal │   │
                 │                                                        │   │
                 │   App process (ColumbaModelBApp)                       │   │
  BLE / RNode ───┼─▶  • radio drivers (Auto / BLE / RNode)                │   │
 (radio peers)   │    • pumps radio frames ─────────────────────────────┘   │
                 │    • ProxyRnsBackend: send/announce/status → NE via IPC   │
                 │    • UI reads and mutates shared GRDB state              │
                 └──────────────────────────────────────────────────────────┘
 ONE destination on the NE, reachable through two transport paths: direct over
 the NE's TCP relay, or peer→radio→app→App-Group bridge→NE. This is standard
 multi-path routing, not a duplicate-destination topology.
```

### Who owns what

| Concern | Owner | Notes |
|---|---|---|
| `lxmf.delivery` destination + identity | **NE** | Identity loaded from the shared keychain access group |
| ReticulumSwift transport + `LXMRouter` | **NE** | The only RNS/LXMF node in this flavor |
| TCP relay interface (`ne-tcp-relay`) | **NE** | Its own `NWConnection`; see the TCP egress note |
| Inbound prove/decrypt/persist/notify | **NE** | `NEDeliveryDelegate` |
| Self-announce of the delivery destination | **NE** | The app cannot announce while suspended |
| Radio interfaces (Auto / BLE / RNode) | **App** | Frames bridged to the NE |
| Send / announce / status requests | **App → NE** | `ProxyRnsBackend` over IPC |
| UI and shared-store operations | **App** | Reads messages and performs conversation/message UI mutations in the shared GRDB store |

## Inbound delivery flow

1. A sender resolves a path to `lxmf.delivery`, learned from the NE's announce, and opens an RNS link or sends opportunistically.
2. Frames arrive at the NE directly over the TCP relay or through radio peer → app radio driver → App Group bridge → NE transport.
3. ReticulumSwift handles the link/resource. LXMFSwift validates the signature, duplicate status, and stamp; decrypts; and persists plaintext to the shared App Group GRDB store.
4. `NEDeliveryDelegate.router(_:didReceiveMessage:)` posts a local `UNUserNotification` and the `network.columba.newMessage` Darwin notification for foreground refresh.
5. The sender receives an RNS delivery proof.
6. On next open, the app reads the persisted message from shared GRDB without re-fetching it.

This path is designed to run in the extension while `ColumbaModelBApp` is suspended or locked.

## Outbound/send flow

1. The app calls `ProxyRnsBackend.sendLxmfMessage(...)`.
2. The proxy marshals a `composeOutbound` envelope over IPC to the extension.
3. `sendLxmfForIPC(...)` builds the `LXMessage` with the shared identity, persists it, and lets the transport select TCP or the App Group radio bridge.
4. Outbound state returns through the GRDB `messages.state` column and the `network.columba.newMessage` Darwin notification.
5. If the extension is unavailable, the app stores the request in the App Group outbox; `NEReticulumNode.drainOutbox` drains it on the next extension start.

## Announce flow

The extension announces its own `lxmf.delivery` destination:

- on node start, after the relay reports connected;
- on relay reconnect, so a restarted relay promptly relearns the path; and
- periodically at the configured interval.

The app's announce action routes through `ProxyRnsBackend.announce` → IPC → `NEReticulumNode.announceForIPC`.

---

## IPC and bridge mechanics

- **Control IPC** (`Sources/Shared/ProxyIPC.swift`) defines Foundation-only `ProxyRequest`/`ProxyResponse` envelopes. `ProxyRnsBackend` (`Sources/RNSBackendProxy/`) sends them with `NETunnelProviderSession.sendProviderMessage`; `PacketTunnelProvider.handleAppMessage` decodes and dispatches to `NEReticulumNode` methods. Keeping this seam Foundation-only prevents RNSAPI/ReticulumSwift types from crossing it.
- **Frame bridge** (`Sources/Shared/AppGroupBridgeInterface.swift`) is a ReticulumSwift `NetworkInterface` registered on the extension transport. It carries app↔extension radio frames through restart-persistent App Group queues (`a2e` and `e2a`) and Darwin notifications.

## Shared state

- **Identity:** The app creates the identity in the shared keychain access group; the extension reads it. `AfterFirstUnlockThisDeviceOnly` accessibility permits extension access while locked after first unlock. App Group defaults carry the resolved group name for locked-start cases.
- **Message store:** LXMFSwift's GRDB/WAL database lives in the App Group. The extension owns inbound delivery persistence and outbound delivery-state updates. `ColumbaModelBApp` currently opens the same database read-write because UI operations update conversations and messages. The `network.columba.newMessage` Darwin notification triggers cross-process refresh. `completeUntilFirstUserAuthentication` file protection permits writes while locked after first unlock.

## Load-bearing invariants

1. **Single node:** The extension alone owns `lxmf.delivery` and `LXMRouter`; `ColumbaModelBApp` does not start a competing destination-owning backend or TCP interface.
2. **Single delivery authority:** The extension handles inbound delivery persistence and app-composed outbound send/persist work. The app may still write UI-managed conversation and message state, but it does not run a second `LXMRouter` or independently terminate inbound transfers.
3. **Durable deduplication:** Deduplication uses path-independent `LXMessage.hash` persisted in GRDB, surviving extension restarts and spanning TCP and radio paths.
4. **Stable node identity:** Shared identity plus shared store recreates the same node after extension restart; on-demand connection can relaunch it.
5. **RNSAPI/ReticulumSwift collision rule:** Files conforming to ReticulumSwift protocols or using its types import ReticulumSwift and Foundation, never RNSAPI. The extension is RNSAPI-free, and the Foundation-only proxy seam carries neither library's types.

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

A release/build-artifact review should confirm both directions of isolation at a high level: shipping contains no extension or Model B crossover, and Model B contains the signed extension but no Python framework, resources, wheels, bridging header, or packaging output. These checks belong in build verification; this document does not define CI implementation.

### TCP egress from inside the tunnel

ReticulumSwift's `TCPTransport` can set `bypassTunnelEgress` (`prohibitedInterfaceTypes = [.other]`) for a physical-interface relay socket rather than routing through the provider's utun. Historical June 2 bring-up showed that the socket was already egressing; this remains a defensive measure rather than the demonstrated fix.

---

## Historical on-device evidence (2026-06-02, iPhone 14)

The following evidence predates the explicit app-target split and must not be presented as current verification:

- **Announce-out:** The extension's `lxmf.delivery` announce was cryptographically validated against RNS `validate_announce`, and the relay installed a path.
- **Inbound LXMF delivery:** A real desktop-peer DIRECT message reached `DELIVERED` at the sender. Extension diagnostics reported `inbound message persisted`; LXMFSwift validated and stored it, and `NEDeliveryDelegate` posted the notification.

The June 2 run did not exercise locked-device delivery or the app-side radio relay path.

### Historical reproduction outline

1. Confirm `rnpath <delivery-dest-hash>` resolves through the relay.
2. Send a DIRECT LXMF message and require sender state `DELIVERED`.
3. Retrieve the extension's `ext-diag.log` from the app data container and confirm `inbound message persisted`.

References named in the original engineering record include `reference_mac_relay_wedge_diagnostic.md` and `track_modelb_tcp_egress_announce_2026-06-02.md`; they are external working notes, not repository documentation links.

## Current verification

Current Model B changes require fresh evidence from the explicit flavor:

1. Build/test the `Columba-ModelB` scheme as a unit so the app, Model B tests, and extension are all covered.
2. Inspect products to confirm the extension is signed and embedded only in `ColumbaModelBApp`, with Model B capabilities present and Python artifacts absent.
3. Inspect the shipping `Columba` product separately to confirm no extension, packet-tunnel entitlement, Model B sources/resources, or Model B runtime behavior is present.
4. On a signed physical device, complete onboarding and its background-delivery gate, grant VPN permission, install/start/wait for the tunnel, and verify status/settings and extension diagnostics.
5. Repeat announce, inbound proof/persist/notification, outbound, restart/outbox, locked-device, and app-radio bridge scenarios. Record device/OS, commit, signing/capability state, and diagnostics.

Until those checks are rerun on the current target graph, the June 2 results remain useful historical evidence, not a claim that the experimental flavor or shipping app currently guarantees background delivery.
