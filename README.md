# Columba

An iOS messaging app built on [Reticulum](https://reticulum.network) for encrypted, off-grid communication. It supports text messaging, voice calls, location sharing, and file transfers over TCP, local Wi-Fi, BLE, and LoRa radio.

## Reticulum hosting

One app target (`ColumbaApp`) and scheme (`Columba`) support two runtime hosting modes:

- **Background (recommended):** Python RNS runs in `ColumbaNetworkExtension`, allowing reception while the app is suspended.
- **Foreground only:** Python RNS runs inside the app, without a VPN configuration. Connections pause when iOS suspends the app; listeners and peers may reconnect when it returns.

Both modes use the same backend facade, command dispatcher, Python engine, durable inbox/outbox, message store, and voice transport. Settings → Reticulum Network → Choose Hosting Mode saves the host for the next fresh app launch. Onboarding also offers foreground mode. There are no separate build flavors.

## Building

Requires Xcode 26+ and iOS 17+.

The app has generated local prerequisites that SPM cannot provide. On a fresh clone, provision the embedded CPython distribution and iOS wheels with the project setup scripts:

```sh
support/fetch-python.sh
support/fetch-wheels.sh
```

These populate the gitignored `Frameworks/Python.xcframework/`, `wheels-iphoneos/`, and `wheels-iphonesimulator/` paths consumed by the `ColumbaApp` packaging phase. See [support/README.md](support/README.md) for pinned versions and packaging details. SPM resolves the Swift package dependencies, but it does not replace these Python prerequisites.

Simulator build:

```sh
xcodebuild -project Columba.xcodeproj \
  -scheme Columba \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

`ColumbaAppTests` tests the shared facade and both adapters. The app embeds the extension and the Python runtime needed by either host. Device provisioning must include the app and extension's Network Extension, App Group, and shared keychain capabilities.

### Local development against unreleased library changes

To work against an in-progress local clone of any Reticulum-stack Swift library without committing a path override, add a per-machine SPM mirror file at `.swiftpm/configuration/mirrors.json` (`.swiftpm/` is gitignored):

```json
{
  "version": 1,
  "object": [
    { "original": "https://github.com/torlando-tech/reticulum-swift.git", "mirror": "/Users/you/repos/reticulum-swift" },
    { "original": "https://github.com/torlando-tech/LXMF-swift.git",      "mirror": "/Users/you/repos/LXMF-swift"      },
    { "original": "https://github.com/torlando-tech/LXST-swift.git",      "mirror": "/Users/you/repos/LXST-swift"      }
  ]
}
```

The top-level key is `object`, not `mirrors`. That is the on-disk format SPM's `MirrorsStorage` reads and the shape written by `swift package config set-mirror`; using `mirrors` produces a no-op load without a warning.

SPM resolves the listed URLs to local checkouts, so library changes are picked up without modifying `Package.swift` or the Xcode project. Remove the file to return to published versions.

## Architecture

- **Embedded Python RNS/LXMF** — one shared engine hosted in the selected process
- **ReticulumSwift** — native Reticulum stack; not the messaging runtime. Carried as a compile-time link by the app for shared-source type compatibility
- **LXMFSwift** — shared LXMF persistence/API surface
- **LXSTSwift** — voice call transport
- **MapLibre** — offline-capable map rendering

See [ARCHITECTURE.md](ARCHITECTURE.md) for target ownership and dependency boundaries.

### Native stamp proof-of-work

The embedded dependencies are immutable commits from the `torlando-tech` forks:

- [Reticulum 1.6.0, `0816be02b5f43b643b980e8262c7c7f2a4fc3d56`](https://github.com/torlando-tech/Reticulum/commit/0816be02b5f43b643b980e8262c7c7f2a4fc3d56) is based directly on upstream 1.6.0 and retains only the native hash-search hook, AutoInterface lifecycle fixes and receive-assembly allocation reductions. Ratchet-file handling, TCP/backbone connection handling and PHY telemetry use unchanged upstream code.
- [LXMF 1.3.0, `09cd6be4324345ed07964e9f6e5372308f6d6883`](https://github.com/torlando-tech/LXMF/commit/09cd6be4324345ed07964e9f6e5372308f6d6883) retains opportunistic receiving metadata and mutex-serialized SQLite compatibility. `LXStamper` is the unchanged upstream wrapper around `RNS.Stamps`; there is no LXMF native-generator registration.

Reticulum owns workblock expansion, fractional-cost quantization, proof validation
and cancellation through its existing stamp jobs. The Python bridge registers
`RNS.Stamps.native_stamp_search(workblock, target, size, stop_check)` once at
startup. Swift only searches for candidate bytes satisfying
`SHA-256(workblock || stamp) <= target`, returning the proof and actual failed
attempt count. The digest is always 32 bytes; candidate sizes are not restricted
to LXMF's 32-byte proofs. There is no integer-cost compatibility path or cost-32
ceiling. Reticulum's X25519 stamped-key search remains upstream.

The bridge passes the full 256-bit target to Swift, clamping Reticulum's
cost-zero target of `2**256` to `2**256-1`, which accepts the same SHA-256 digests.
Swift reuses the hashed workblock prefix, and the bridge polls signed native job
entry points for completion and cancellation without Python callback trampolines.

Receive assembly still uses complete resource buffers and existing bytes/file
callback interfaces. The retained allocation reductions do not make resource
reception constant-memory or eliminate file I/O; upstream decompression limits
remain in force.

On macOS, the native/reference regression compiles the production Swift stamper,
generates a separate proof with Python RNS, and submits both signed messages to
an LXMF receiver with stamp enforcement enabled. It also checks that a proof
valid at cost 8 is rejected at cost 8.5:

```sh
python3 -B -m unittest Tests.static.test_native_stamp_reference -v
```

Use host-compatible `cryptography` and `pyserial`, with the pinned pure-Python
RNS/LXMF packages on `PYTHONPATH`. The macOS CI job prepares these separately
from the iOS binary wheels.

## Acknowledgements

- This work was partially funded by the [Solarpunk Pioneers Fund](https://solarpunk-pioneers.org)
- K8 and 405nm for generously donating for an iPhone
- [Reticulum](https://reticulum.network), [LXMF](https://github.com/markqvist/LXMF), and [LXST](https://github.com/markqvist/LXST) by Mark Qvist

## License

[MPL 2.0](LICENSE.md)
