# Columba architecture

`ColumbaApp` is the only application target. It embeds `ColumbaNetworkExtension`; `ColumbaAppTests` is the only hosted unit-test target. Debug and Release use the same source graph and hosting choices.

## The process seam

```text
UI / AppServices / Messaging / NodeNetworkTransport
                       │ RnsBackend facets
                 ProxyRnsBackend
                    ╱         ╲
        LocalNodeAdapter    TunnelManager.proxySend
                    ╲         ╱
                NodeCommandDispatcher
                       │
              PythonNodeEngine / PythonNodeRuntime
                       │
                  app/rns_bridge.py
```

`BackendFactory` selects only the command transport. Foreground mode dispatches locally; background mode sends the same framed `ProxyRequest` to the extension. Both return the same `ProxyResponse`. There is one implementation of message fields, fallback, event mapping, replay acknowledgment, and voice link handling. UI code does not access the Python interpreter or a concrete Python backend.

`Sources/RNSHost` compiles into both hosts. The shared engine imports Foundation/Security and exposes serialized data; it does not import RNSAPI, ReticulumSwift, or LXMFSwift. Each process bundles CPython and its resources, but only the selected host initializes RNS. Native BLE and RNode bindings execute inside that host; there is no app-owned BLE relay competing with the extension radio.

## Ownership and lifecycle

Background is the default. Onboarding can explicitly choose foreground without installing a VPN profile. Settings saves a choice for the next fresh application launch; it does not move live interfaces between interpreters. This preserves the existing AutoInterface restriction: same-process RNS restart may require relaunch because multicast sockets are not fully released.

Before foreground startup, the app stops the existing tunnel, then disables VPN on-demand and persists the disarm. The NetworkExtension preferences calls (`loadAllFromPreferences`/`saveToPreferences`) are awaited with a deadline and never cancelled: their neagent completion can be lost while a session is active, and a lost completion must park its own task, not startup. A timed-out disarm is best-effort — a surviving armed config is safe because delayed extension startup checks the selected host again before initializing RNS. A process-held `flock` lease in the App Group container prevents either process from starting another node before the previous owner releases it. The kernel releases the lease after process death. Failed Python cleanup retains ownership rather than admitting a competing node. iOS SIGKILLs (0xdead10cc) a suspended app that holds a shared-container file lock, so the app releases the lease when it backgrounds and re-acquires it on foreground return; the extension's host re-check covers the free-lease window.

## Durable state

Both hosts use the same per-identity App Group directory, shared keychain identity, and GRDB message store. A one-time migration copies missing legacy app-local RNS state without replacing newer shared state. The existing GRDB migration owns SQLite/WAL/SHM consistency.

Python projects inbound messages into the shared store. `NodeInboundReplay` runs the common app field-processing path, including reactions, replies, telemetry, and attachments. Propagation synchronization awaits replay catch-up. The durable event inbox remains bounded and is acknowledged only after consumption. Stable send IDs and the durable outbox carry complete fields and propagated fallback across host/process restarts.

The persisted propagation configuration is restored before recovering outbox sends when iOS starts the extension without the app. Live relay selection, sync/cancellation, discovery, transfer limits, and peer identity retention cross typed commands through the same dispatcher in either mode.

Propagation uploads and downloads share the router's outbound relay link. The Python sync bridge waits for a pre-existing pending link within the sync deadline, then explicitly starts retrieval; it never treats the previous sync's terminal state as the current result. Already-closed links are discarded on retry, while a link that closes during the wait reports `link_failed`. Failed operations report zero received messages rather than a previous sync's count.

## Project maintenance and validation

Run `ruby support/configure-unified-hosting.rb` to reconcile the shared source graph. The old configure/embed/isolation entry points delegate to it and cannot recreate alternate app flavors. `support/verify-flavor-artifact.py unified <app>` checks both host payloads, the embedded extension, native ABI exports, framework linkage, and signing entitlements. Its legacy modes remain for inspecting historical artifacts.

The CI app lane builds/tests the `Columba` scheme and verifies Debug and post-processed Release artifacts. UI tests run in a separate lane. `Tests/host-contracts` executes the production Foundation-only ownership, storage, and command seam on Linux or Darwin; hosted Swift tests cover both adapters, facade behavior, and drain races.
