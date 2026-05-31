# Columba-iOS interop test harness

Hermetic end-to-end interop suite for Columba-iOS, modelled on Columba-Android's `tests/interop/`. Pins iOS-side wire-format correctness against a reference Sideband peer running headless on the same host.

## Topology

```
┌─────────────────────────────────┐       ┌──────────────────────────────┐
│ iOS Simulator (iPhone 17 …)     │       │ Sideband-headless peer        │
│   Columba.app                    │       │   sbapp.sideband.core (in-    │
│   identity: 7030e48e…            │       │   process via peer_sideband)  │
│   TCPClient → 127.0.0.1:4242     │       │   identity: 95617c21…         │
│   ↑                              │       │   ↑ (RNS shared instance)     │
└───┼──────────────────────────────┘       └───┼──────────────────────────┘
    │                                          │
    └─────────────┐         ┌──────────────────┘
                  ▼         ▼
              ┌───────────────────┐
              │ rnsd (Mac)        │
              │ TCPServer :4242   │
              │ share_instance Y  │
              └───────────────────┘
```

All three RNS endpoints share the host transport (rnsd bridges the simulator's TCPClient to Sideband's shared-instance socket). No physical phone required.

## Components

- **`peer_sideband.py`** — `SidebandPeer`, the in-process Sideband daemon wrapper. Copied from Columba-Android's `tests/interop/peer_sideband.py` (commit `cf18d31`). Provides `start()`, `identity_hex`, `send_text()`, `wait_for_message()`, and a `wait_for_tapped_message()` that sees every inbound `LXMessage` *before* Sideband filters it — the diagnostic surface for "iOS shows delivered but message disappears" bugs (the proof fires at the RNS layer before any LXMF processing — see `LXMRouter.delivery_packet:1822`).
- **`run_peer.py`** — Standalone runner: `python run_peer.py` to boot the peer, watch the tap, and print every inbound `LXMessage` (source, content, signature_validated, field-key set). Used interactively while debugging; the pytest harness will drive `SidebandPeer` directly.
- **`flows/`** — Maestro YAML flows for driving the iOS Columba simulator UI.
- **`screenshots/`** — Where Maestro test runs write `takeScreenshot:` outputs. Gitignored.

## Prerequisites

- macOS with Xcode 26+ and an iOS 26 simulator booted
- `rnsd` running with a TCPServer on `127.0.0.1:4242` and `share_instance = Yes`
- Sideband checkout at `~/repos/Sideband`
- Python venv with the RNS / LXMF wheels installed (the same venv `rnsd` uses is fine — `~/.reticulum-host/venv`)
- `maestro` installed (`brew install maestro`)
- Columba.app built for the simulator (see "Build" below)

## Build

```bash
cd ~/repos/Columba-iOS
xcrun simctl boot "iPhone 17"
xcodebuild -project Columba.xcodeproj -scheme Columba -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -derivedDataPath /tmp/columba-sim-build build

xcrun simctl install booted /tmp/columba-sim-build/Build/Products/Debug-iphonesimulator/ColumbaApp.app
```

## Run a manual diagnostic

In one shell, boot the Sideband peer:

```bash
~/.reticulum-host/venv/bin/python tests/interop/run_peer.py --watch
# prints identity_hex; leave running
```

In another shell, launch Columba on the simulator with the TCP-hub env so it
joins the same rnsd:

```bash
SIMCTL_CHILD_COLUMBA_TCP_HUB=127.0.0.1:4242 \
  xcrun simctl launch booted network.columba.Columba
```

Drive a send via Maestro:

```bash
maestro --device "$(xcrun simctl list devices booted | awk '/Booted/{print $NF}' | tr -d '()')" \
  test tests/interop/flows/send_text_to_sideband.yaml
```

Watch the peer log — `tap` prints every inbound `LXMessage` with its `signature_validated` flag and the field-key set. If iOS Columba reports "delivered" but no tap entry appears for the corresponding text, the bug is on the iOS send wire. If the tap entry shows `signature_validated=False`, iOS's announce isn't reaching Sideband. If the tap entry has the right content but Sideband's DB doesn't, the issue is downstream of the upstream LXMF callback.

## Future: pytest-driven runs

Like Columba-Android's suite, individual interop tests will be pytest cases that:
1. Spawn `SidebandPeer`,
2. Drive Maestro to send from iOS,
3. Assert on the tap (and/or the Sideband DB),
4. Reverse direction: `peer.send_text(ios_hash, …)` + Maestro screenshot/assertion that the bubble appeared on iOS.

The `screenshots/` directory captures the per-step UI state for triage when an assertion fails.
