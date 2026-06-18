# Columba-iOS interop test harness

Hermetic end-to-end interop suite for Columba-iOS, modelled on Columba-Android's
`tests/interop/`. Pins iOS-side wire-format correctness against a reference
Sideband peer running headless on the same host. The pytest suite
(`test_attachments.py`, `test_telemetry.py`) drives the iOS Columba simulator
via Maestro / `lxma://` deep links and asserts delivery on the Sideband side
(and the reverse). 14 cases: text / image (opportunistic, direct, propagated) /
file, both directions, plus location telemetry, custom-meta, periodic-share
toggle, and cease.

## Topology

```
┌──────────────────────────────────┐      ┌──────────────────────────────┐
│ iOS Simulator (iPhone 17)        │      │ Sideband-headless peer        │
│   Columba.app                    │      │   sbapp.sideband.core (in-    │
│   TCPClient → 127.0.0.1:4242     │      │   process via peer_sideband)  │
│   (auto-seeded by conftest)      │      │   ↑ shared instance :37428    │
└───┼──────────────────────────────┘      └───┼──────────────────────────┘
    │                                          │
    │  TCP :4242                  LocalServer  │ :37428
    └──────────────┐         ┌─────────────────┘
                   ▼         ▼
            ┌─────────────────────────────┐
            │ lxmd  (network.lxmf.lxmd)    │  ← owns the shared RNS instance
            │   "Columba Hub" prop node    │     enable_transport = True
            │   TCPServer        :4242     │     share_instance   = Yes
            │   LocalServer      :37428    │
            └─────────────────────────────┘
              ▲                 ▲
              │ (also clients of the shared instance)
           rnsd               nomadnet
```

**`lxmd` — not rnsd — owns the shared RNS instance + the `:4242` TCPServer.**
rnsd and nomadnet run alongside it as shared-instance *clients*. lxmd is the
transport node (`enable_transport = True`) that bridges the sim's TCPClient to
Sideband's shared-instance connection, so an announce/message from one side
reaches the other. No physical phone required.

## Components

- **`conftest.py`** — pytest fixtures. Session-scoped, self-contained:
  - `sideband` — boots the in-process `SidebandPeer` once per session.
  - `_ensure_sim_interface` — **auto-seeds** a TCP-client interface
    (`127.0.0.1:4242`) into Columba's interface store and relaunches, so a
    fresh sim install (which comes up with 0 interfaces) bridges to lxmd with
    no manual "Settings → Add Interface" step. Override host/port with
    `RNSD_TCP_HOST` / `RNSD_TCP_PORT`.
  - `_bootstrap_paths` — cold-starts the bidirectional path table (each side
    must have heard the other's announce), then pins lxmd's propagation node
    on the sim (discovered via `lxmd --status`) so the propagated test runs
    deterministically instead of skipping on lxmd's 5-min announce cadence.
  - `Simulator` helper — reads the app's `Documents/diag.log` (the
    `[RNS] started/inbound/announce/delivery` lines — note the backend-agnostic
    `[RNS]` prefix, renamed from `[PY]` in the dual-backend refactor), fires
    `lxma://` deep links via Maestro, and resolves the sim's identity / LXMF
    delivery hash.
- **`peer_sideband.py`** — `SidebandPeer`, the in-process Sideband daemon
  wrapper. Provides `start()`, `identity_hex`, `send_text()`,
  `wait_for_message()`, and `wait_for_tapped_message()` that sees every inbound
  `LXMessage` *before* Sideband filters it — the diagnostic surface for "iOS
  shows delivered but message disappears" bugs (fires at the RNS layer before
  any LXMF processing). Teardown uses `SidebandCore.cleanup()`.
- **`run_peer.py`** — Standalone runner (`python run_peer.py`) to boot the peer
  interactively and print every inbound `LXMessage`. Used while debugging; the
  pytest suite drives `SidebandPeer` directly.
- **`flows/`** — Maestro YAML flows that drive the Columba simulator UI.
- **`screenshots/`** — Maestro `takeScreenshot:` outputs (gitignored).

## Prerequisites

- macOS with Xcode 26+ and **one** iOS simulator booted (iPhone 17).
- **`lxmd` running** as the shared instance: `enable_transport = True`,
  `share_instance = Yes`, and a `[[TCP Server]]` on `127.0.0.1:4242`
  (config in `~/.lxmd/config` + `~/.reticulum/config`). rnsd/nomadnet may run
  alongside as clients but lxmd is what the sim and Sideband bridge through.
- Sideband checkout at `~/repos/Sideband` (override with `SIDEBAND_SRC`).
- A Python env with `RNS` / `LXMF` / `pytest` (the host venv
  `~/.reticulum-host/venv` works).
- `maestro` installed (`brew install maestro`); JDK 21 on `JAVA_HOME` for it.
- Columba.app **installed** on the booted sim (built `Debug` so the `lxma://`
  test deep links — which are `#if DEBUG`-gated in production — are present).
  The TCP interface to lxmd is seeded automatically by the suite; you do **not**
  need to configure it by hand.

## Build + install the app

```bash
cd ~/repos/Columba-iOS
xcrun simctl boot "iPhone 17"
xcodebuild -scheme Columba -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -derivedDataPath /tmp/columba-sim-build build
xcrun simctl install booted \
  /tmp/columba-sim-build/Build/Products/Debug-iphonesimulator/ColumbaApp.app
```

## Run the suite

```bash
cd ~/repos/Columba-iOS/Tests/interop
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
python3 -m pytest -v
```

The session fixtures handle everything else: seed the sim's lxmd interface,
boot the Sideband peer, bootstrap paths, pin the propagation node. Expect
**14 passed**. (A run takes ~5 min — Sideband boot + a Maestro flow / deep-link
send + delivery wait per case.)

## Manual diagnostic

```bash
SIDEBAND_SRC=~/repos/Sideband python3 run_peer.py   # prints identity_hex, watches the tap
```
Then drive a flow against the booted sim:
```bash
maestro --device "$(xcrun simctl list devices booted | awk '/Booted/{print $NF}' | tr -d '()')" \
  test flows/send_text_to_peer.yaml
```
The tap prints every inbound `LXMessage` with its `signature_validated` flag and
field-key set. If Columba reports "delivered" but no tap entry appears, the bug
is on the iOS send wire; if the tap shows `signature_validated=False`, iOS's
announce isn't reaching Sideband; if the content is right but Sideband's DB
isn't, the issue is downstream of the upstream LXMF callback.

## Troubleshooting

- **Every case errors at setup with "sim never heard the peer announce"** (and
  more broadly, devices connect but receive nothing — `rx=0` on their links):
  **lxmd is wedged.** It accepts TCP connections but stops routing packets
  (symptom: `~/.reticulum/logfile` stops growing, lxmd at 0% CPU). This also
  takes down real phones bridging through it. Fix — bounce it:
  ```bash
  launchctl kickstart -k gui/$(id -u)/network.lxmf.lxmd
  ```
  Confirm it recovered: `lxmd --status` shows peers/traffic and the logfile
  resumes `Valid announce for …` lines.
- **`test_image_..._propagated` skips:** the suite pins lxmd's prop node via
  `lxmd --status`; a skip means lxmd was unreachable at bootstrap. Check lxmd
  is up and `--status` works.
- **Suite can't read the sim identity / "Couldn't find `[RNS] started…`":**
  the app must be a `Debug` build (so the deep-link handlers exist) and must
  have launched at least once (it clears + writes `diag.log` on launch).
