# Columba

An iOS messaging app built on [Reticulum](https://reticulum.network) for encrypted, off-grid communication. It supports text messaging, voice calls, location sharing, and file transfers over TCP, local Wi-Fi, BLE, and LoRa radio.

## Build flavors

Columba has two compile-time app flavors. They are separate targets and schemes, not a runtime preference.

| Flavor | App target | Scheme | Runtime flag | Purpose |
|---|---|---|---|---|
| Shipping | `ColumbaApp` | `Columba` | `COLUMBA_RUNTIME_PYTHON` | Embedded Python RNS/LXMF runtime; this is the standard build |
| Experimental Model B | `ColumbaModelBApp` | `Columba-ModelB` | `COLUMBA_RUNTIME_MODEL_B` | Native proxy/Network Extension background-delivery experiment; not part of the shipping artifact |

The shipping app owns `Python.xcframework`, the Python bridge and runtime, Python model/backend sources, the Python `app/` resources, wheels, standard-library installation, and packaging. It has no Network Extension target dependency or embed, no packet-tunnel entitlement, and no Model B lifecycle, UI, or proxy behavior. Its default Internet TCP delivery is foreground/opportunistic; the shipping artifact does not guarantee background Internet TCP delivery.

`ColumbaApp` still links `ReticulumSwift` because shared public `MessageRepository`/`LXMFSwift` signatures expose ReticulumSwift types. That linkage does not mean the shipping app runs the native Model B stack.

The experimental app owns `ProxyRnsBackend`, Model B host/proxy/App Group IPC sources, direct ReticulumSwift linkage, and the dependency and signed embed for `ColumbaNetworkExtension`. It excludes the Python framework, Python-only sources and resources, wheels, bridging header, and Python packaging phases. See [Model B — Background LXMF Delivery](docs/MODEL_B_BACKGROUND_DELIVERY.md).

Build flavor is fixed at compile time. Each app target has exactly one canonical runtime flag. The old `Columba-Swift` scheme, `Debug-Swift`/`Release-Swift` configurations, and `BackendPreference.modelB` runtime selector are retired. `COLUMBA_BACKEND_SWIFT` remains on Model B as a temporary compatibility condition for a transport-settings branch; it is not the architecture selector. A persisted `useSwiftBackend` value does not select the architecture.

## Building

Requires Xcode 15+ and iOS 17+.

The shipping Python build has generated local prerequisites that SPM cannot provide. On a fresh clone, provision the embedded CPython distribution and iOS wheels with the project setup scripts:

```sh
support/fetch-python.sh
support/fetch-wheels.sh
```

These populate the gitignored `Frameworks/Python.xcframework/`, `wheels-iphoneos/`, and `wheels-iphonesimulator/` paths consumed by the `ColumbaApp` packaging phase. See [support/README.md](support/README.md) for pinned versions and packaging details. SPM resolves the Swift package dependencies, but it does not replace these Python prerequisites.

Standard shipping simulator build:

```sh
xcodebuild -project Columba.xcodeproj \
  -scheme Columba \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Experimental Model B simulator build:

```sh
xcodebuild -project Columba.xcodeproj \
  -scheme Columba-ModelB \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
```

`Columba-ModelB` is the canonical path for the experimental flavor: its Build action includes `ColumbaModelBApp` and `ColumbaNetworkExtension`, and its Test action includes `ColumbaModelBAppTests`. Use `build-for-testing` instead of `build` when the test bundle must also be compiled. Do not build the extension separately as the normal workflow. The `Columba` scheme is shipping-only.

Physical-device builds require a valid signing team and provisioning for the selected app. Model B device builds must also sign the extension and provision its Network Extension and App Group capabilities.

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

- **Embedded Python RNS/LXMF** — default shipping messaging runtime
- **ReticulumSwift** — native Reticulum stack used directly by experimental Model B and linked by shipping for shared public type signatures
- **LXMFSwift** — shared LXMF persistence/API surface and Model B router
- **LXSTSwift** — voice call transport
- **MapLibre** — offline-capable map rendering

See [ARCHITECTURE.md](ARCHITECTURE.md) for target ownership and dependency boundaries.

## Acknowledgements

- This work was partially funded by the [Solarpunk Pioneers Fund](https://solarpunk-pioneers.org)
- K8 and 405nm for generously donating for an iPhone
- [Reticulum](https://reticulum.network), [LXMF](https://github.com/markqvist/LXMF), and [LXST](https://github.com/markqvist/LXST) by Mark Qvist

## License

[MPL 2.0](LICENSE.md)
