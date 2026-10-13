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

## Acknowledgements

- This work was partially funded by the [Solarpunk Pioneers Fund](https://solarpunk-pioneers.org)
- K8 and 405nm for generously donating for an iPhone
- [Reticulum](https://reticulum.network), [LXMF](https://github.com/markqvist/LXMF), and [LXST](https://github.com/markqvist/LXST) by Mark Qvist

## License

[MPL 2.0](LICENSE.md)
