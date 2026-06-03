# Model B — Background LXMF Delivery

How Columba-iOS delivers an LXMF message (and a notification) while the app is
backgrounded, suspended, or **locked**, without APNS — by running the real
Reticulum + LXMF stack inside a Network Extension that *completes* delivery
(proves, decrypts, persists, notifies), rather than just sniffing.

> Status: inbound delivery + announce propagation **verified on-device**
> (2026-06-02, iPhone 14). See "Verified on-device" below.
>
> Companion docs: the per-phase implementation spec lives in the Obsidian vault
> (`80 Assistant/Memory/Columba-iOS/track_a_model_b_implementation_spec.md`,
> A0–A5, cited to `file:line`); NE security threat model in
> `track_c5_ne_security_threat_model.md`; App-Store framing in
> `app_store_review_packet_tunnel_ne.md`.

---

## Why this shape ("Model B")

A suspended iOS app cannot be woken to finish network work (Apple DTS 769398), so
the only way to deliver an LXMF message while the phone is locked is to have a
**separately-scheduled process** that owns the messaging endpoint and completes
delivery itself. The `NEPacketTunnelProvider` Network Extension (NE) is that
process: iOS keeps it running for the active VPN/tunnel, independent of the app's
lifecycle.

**Model B = the NE is the *canonical* node.** It owns the single
`lxmf.delivery` destination and terminates every transfer. The app is a
transport/UI satellite. The alternative (Model A: app owns the node, NE sniffs
and hands off) was rejected — two processes contending for one destination causes
path-flap, link double-response, and cross-process receive-dedup races. Model B
has exactly one node, one writer, one place for dedup.

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
                 │     • posts UNUserNotification + dbChanged Darwin notif │   │
                 │                                                        │   │
                 │   App process (ColumbaApp)                             │   │
  BLE / RNode ───┼─▶  • radio drivers (Auto / BLE / RNode)                │   │
 (radio peers)   │    • pumps radio frames ─────────────────────────────┘   │
                 │    • ProxyRnsBackend: send/announce/status → NE via IPC   │
                 │    • UI reads the shared GRDB (read-only)                 │
                 └──────────────────────────────────────────────────────────┘
 ONE destination on the NE, reachable via two transport paths: direct over the
 NE's TCP relay, or peer→radio→app→App-Group bridge→NE. Standard multi-path
 routing — no duplicate-destination anomaly.
```

### Who owns what

| Concern | Owner | Notes |
|---|---|---|
| `lxmf.delivery` destination + identity | **NE** | identity loaded from the shared keychain access group |
| ReticulumSwift transport + `LXMRouter` | **NE** | the only RNS/LXMF node in the system |
| TCP relay interface (`ne-tcp-relay`) | **NE** | its own `NWConnection`; see "TCP egress" note |
| Inbound prove/decrypt/persist/notify | **NE** | `NEDeliveryDelegate` |
| Self-announce of the delivery dest | **NE** | app can't announce while suspended |
| Radio interfaces (Auto / BLE / RNode) | **App** | frames bridged to the NE |
| Send / announce / status requests | **App → NE** | via `ProxyRnsBackend` over IPC |
| UI, shared-store reads | **App** | read-only reader of the NE's GRDB store |

---

## Inbound delivery flow (the headline path)

1. A sender resolves a path to `lxmf.delivery` (learned from the NE's announce)
   and opens an RNS **link**, or sends opportunistically.
2. Frames arrive at the NE either directly over the **TCP relay**, or via a
   radio peer → app radio driver → **AppGroupBridge** → NE transport.
3. The NE's `ReticulumSwift` transport handles the link / resource; the
   `LXMFSwift` `LXMRouter` validates (signature / duplicate / stamp), decrypts,
   and **persists** the plaintext to the shared App-Group GRDB store.
4. `NEDeliveryDelegate.router(_:didReceiveMessage:)` fires:
   - posts a local `UNUserNotification` (sender + short preview), and
   - posts a `dbChanged` Darwin notification so a foregrounded app refreshes.
5. The sender receives a **delivery proof** (RNS link delivery).
6. On next open, the app reads the message from the shared GRDB — no re-fetch.

This whole path runs in the NE while the app is suspended/locked.

## Outbound / send flow

1. The app composes a message and calls `ProxyRnsBackend.sendLxmfMessage(...)`.
2. That marshals a `composeOutbound` envelope (dest, content, `LxmfFieldCodec`-
   packed fields, method) over the IPC seam to the NE.
3. The NE's `sendLxmfForIPC(...)` builds the `LXMessage` with the **shared**
   identity, persists it, and `transport.send` selects the path automatically
   (path-table lookup → TCP direct, or via the AppGroupBridge → app → radio).
4. Outbound state flows back via the GRDB `messages.state` column + `dbChanged`.
5. **Durable outbox:** if the NE isn't up when the app sends, the request is
   persisted to an App-Group outbox and drained on the next NE start
   (`NEReticulumNode.drainOutbox`).

## Announce flow

The NE announces its own `lxmf.delivery` destination — the app can't drive
announces while suspended:

- **on node start**, once the relay reports connected (`startAnnounceScheduler`
  → `waitForRelayConnected` → `selfAnnounce`);
- **on relay (re)connect** (`onRelayReconnected`, wired via
  `transport.setOnInterfaceConnected`) — so a relay that restarted (and lost its
  path table) promptly relearns us, instead of waiting for the interval;
- **periodically**, on the user's configured interval (mirrors the app's
  `AutoAnnounceManager`).

The app's "announce now" button routes through `ProxyRnsBackend.announce` → IPC
→ `NEReticulumNode.announceForIPC`.

---

## IPC + bridge mechanics

- **Control IPC** (`Sources/Shared/ProxyIPC.swift`): a Foundation-only
  `ProxyRequest`/`ProxyResponse` envelope (magic + version framed). The app's
  `ProxyRnsBackend` (`Sources/RNSBackendProxy/`) sends it over
  `NETunnelProviderSession.sendProviderMessage`; the NE decodes it in
  `PacketTunnelProvider.handleAppMessage` and dispatches to `NEReticulumNode`'s
  `…ForIPC` methods. The seam is Foundation-only so the NE never imports RNSAPI
  (see the collision rule).
- **Frame bridge** (`Sources/Shared/AppGroupBridgeInterface.swift`): a real
  `ReticulumSwift.NetworkInterface` (`mode = .full`, so announces propagate both
  ways) registered on the NE's transport. It carries radio frames app↔NE over an
  App-Group `SharedFrameQueue` (POSIX-flock'd file, restart-idempotent — survives
  NE jetsam) split into two named unidirectional queues (`a2e` / `e2a`), with a
  `radioFrameReady` Darwin notification app→NE and `packetReady` NE→app.

## Shared state

- **Identity:** shared keychain access group
  (`$(AppIdentifierPrefix)network.columba.Columba.shared`). The app creates the
  identity and writes it to the shared group; the NE reads it
  (`NEReticulumNode.loadSharedIdentity`). Accessibility
  `…AfterFirstUnlockThisDeviceOnly` (NE-readable while locked, post-first-unlock).
  The app also publishes the *resolved* group name to App-Group UserDefaults so
  the NE can resolve it even when the bundle-seed probe can't run (locked).
- **Message store:** `LXMFSwift.LXMFDatabase` (GRDB, WAL) in the App-Group
  container. **Single writer = the NE**; the app opens it **read-only**. Cross-
  process refresh is the `dbChanged` Darwin notification (GRDB observation does
  not cross processes). File protection
  `completeUntilFirstUserAuthentication` so it's writable while locked.

---

## Load-bearing invariants

1. **Single node = the NE.** The app owns no `lxmf.delivery` destination and no
   `LXMRouter`. On launch the app must NOT start a competing destination-owning
   backend (gated for Model B in `AppServices` / the startup interface loop —
   e.g. it skips the app-side TCP interface).
2. **Single writer = the NE.** The app is read-only on the GRDB store; outbound
   composed in-app is *handed to the NE to send + persist*.
3. **Durable dedup.** Dedup keys on the path-independent
   `LXMessage.hash`; it lives in the GRDB store (`messageExists`) so it survives
   an NE restart and spans transport paths (TCP copy == BLE copy).
4. **Always-the-node.** The node identity is a pure function of (shared identity
   + shared store), so NE jetsam/restart is transparent — it comes back as the
   same node. On-demand connect (`NEOnDemandRuleConnect`) relaunches it.
5. **The RNSAPI / ReticulumSwift collision rule.** RNSAPI's `Compat` layer
   re-declares the same type names as `ReticulumSwift`. Files that conform to
   `ReticulumSwift` protocols or use its types import **ReticulumSwift (+
   Foundation) ONLY, never RNSAPI**. The NE target is entirely RNSAPI-free; the
   proxy seam (`ProxyIPC`) is Foundation-only so no RNSAPI/ReticulumSwift type
   ever crosses it. `AppServices` stays RNSAPI-typed; LXMFSwift is confined to
   `MessageRepository`.

---

## Build / packaging gotchas

- **Build the NE via the `ColumbaNetworkExtension` scheme**, not the
  `Columba-Swift` app scheme — the app scheme does NOT compile the NE (a false-
  green trap). See `reference_ne_build_scheme.md`.
- Model B code is on the **`Debug-Swift` / `Release-Swift`** configs
  (`COLUMBA_BACKEND_SWIFT` + `ENABLE_NETWORK_EXTENSION`).
- The NE is embedded + signed via `support/embed-ne.rb`; its deps
  (ReticulumSwift + LXMFSwift) via `support/add-ne-backend-deps.rb`.
- **Runtime gate:** `BackendPreference.modelB` (app) and
  `NEReticulumNode.modelBNodeEnabled` (NE) read the shared App-Group flag
  `modelBBackgroundNE`. Model B only works on the Swift backend.

### TCP egress from inside the tunnel
`reticulum-swift`'s `TCPTransport` sets `bypassTunnelEgress`
(`prohibitedInterfaceTypes = [.other]`) when the NE host enables it, so the
relay socket uses a physical interface rather than the provider's own utun.
(Note: as of the 2026-06-02 bring-up this turned out *not* to be the actual
egress fix — the NE socket was already egressing fine; it's retained as a
defensive measure. See `track_modelb_tcp_egress_announce_2026-06-02.md`.)

---

## Verified on-device (2026-06-02, iPhone 14)

- **Announce-out:** the NE's announce for `lxmf.delivery` is cryptographically
  valid (verified the on-wire bytes against RNS's own `validate_announce` —
  signature + destination hash) and the relay installs a path to it.
- **Inbound LXMF delivery (headline):** a real LXMF message sent from a desktop
  peer to the delivery dest reached `state = DELIVERED` (delivery proof) on the
  sender, and the NE logged `inbound message persisted` — LXMF-swift validated +
  stored to the shared GRDB and `NEDeliveryDelegate` posted the notification.

**How to re-test (desktop peer with RNS/LXMF):**
1. Confirm reachability: `rnpath <delivery-dest-hash>` resolves on the relay
   host. (If not, suspect a wedged relay daemon — see
   `reference_mac_relay_wedge_diagnostic.md`.)
2. Send an LXMF message to the dest (DIRECT). It should reach `DELIVERED`.
3. Pull the NE's `ext-diag.log` (host copies it to the app's Documents on
   launch; retrieve via `devicectl … copy from --domain-type appDataContainer`)
   and confirm `inbound message persisted`.

---

## Known gaps / TODO (as of 2026-06-02)

- **UI status reflects the app's interfaces, not the NE's.** In Model B the app
  owns no TCP interface, so its interface card shows the TCP relay as
  "disconnected" even though the NE's relay is connected. The card (and the
  "announce" button) should read NE state via `ProxyRnsBackend.statusSnapshot` /
  route through the proxy.
- **Temporary bring-up state to revert before ship:** `BackendPreference.modelB`
  and `NEReticulumNode.modelBNodeEnabled` are defaulted ON for testing; the NE
  diagnostic logging (announce EMITTED / self-announce / relay-reconnect) and the
  reticulum-swift `TCPTransport` egress diagnostic are temporary. Add a real UI
  toggle for Model B.
- **Not yet exercised:** delivery while the device is locked (mechanism is in
  place — file protection + NE-runs-while-locked); the app-side radio relay
  (Auto/BLE/RNode → AppGroupBridge → NE).
