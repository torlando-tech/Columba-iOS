# Columba-iOS Architecture

Columba has one shipping app target and one isolated experimental app target. Flavor selection is a compile-time target boundary; it is not a runtime backend preference or a build-configuration variant.

## App flavors

| Concern | Shipping Python flavor | Experimental Model B flavor |
|---|---|---|
| App target | `ColumbaApp` | `ColumbaModelBApp` |
| Scheme | `Columba` | `Columba-ModelB` |
| Canonical runtime condition | `COLUMBA_RUNTIME_PYTHON` | `COLUMBA_RUNTIME_MODEL_B` |
| Messaging runtime | Embedded Python RNS/LXMF (`PythonRNSBackend`) running in-process in the app | `ProxyRnsBackend` (Foundation-only IPC) reaching the same embedded-Python RNS node running in-process in `ColumbaNetworkExtension` |
| Runtime-owned sources | Python bridge/runtime, Python backend and models, Python network transport | Model B proxy, host lifecycle, App Group IPC/frame seams, BLE/RNode proxy lifecycle, background-delivery UI |
| Runtime-owned packaging | `Python.xcframework`, Python `app/` resources, wheels, standard library, bridging header, install/embed phases | Signed `ColumbaNetworkExtension.appex`; no Python framework, resources, wheels, bridging header, or Python packaging |
| Extension relationship | No target dependency, embed, packet-tunnel entitlement, or Model B lifecycle/UI/proxy behavior | Direct target dependency and signed embed; owns VPN permission, install/start/wait lifecycle, status/settings UI, onboarding gate, and diagnostics |
| Delivery expectation | Internet TCP delivery is foreground/opportunistic; no guaranteed background Internet TCP delivery | Experimental background delivery while the extension is active |

Both apps retain shared product/UI code. Neither flavor runs a native ReticulumSwift stack: the engine is embedded-Python RNS in both, hosted in the app (shipping) or the Network Extension (Model B). Both app targets still carry a compile-time `ReticulumSwift` link only because retained shared sources reference `ReticulumSwift`/`LXMFSwift` types in their signatures (e.g. `MessageRepository`, `LocationSharingManager`, `CeaseTelemetry`) or `import ReticulumSwift` (e.g. `SwiftRNSBackend`, `NomadNetFetch`, `AppGroupBridgeInterface`). That linkage satisfies the compiler; it does not mean either app runs a native RNS runtime.

Each app target must define exactly one canonical runtime condition. `Columba-Swift`, `Debug-Swift`, `Release-Swift`, and the `BackendPreference.modelB` selector are retired. `COLUMBA_BACKEND_SWIFT` remains on Model B as a temporary compatibility condition for transport settings, but it does not select the runtime architecture. Persisted `useSwiftBackend` state has no architectural effect. Debug and Release choose optimization, not runtime flavor.

## Scheme and target graph

- `Columba` builds and runs only the shipping `ColumbaApp`; its test action hosts `ColumbaAppTests`. It has no Network Extension dependency or embed.
- `Columba-ModelB` is the canonical experimental workflow. Its Build action includes `ColumbaModelBApp` and `ColumbaNetworkExtension`, and its Test action includes `ColumbaModelBAppTests`; the app depends on and embeds the signed extension.
- `ColumbaNetworkExtension` runs the node engine as embedded-Python RNS; its `ReticulumSwift`/`LXMFSwift` entries are compile-time `packageProductDependencies` only (they satisfy `import ReticulumSwift` in the shared files compiled into the NE, e.g. `NomadNetFetch.swift` / `AppGroupBridgeInterface.swift`). They are **not** in the NE's frameworks build phase, so ReticulumSwift is not linked into the extension binary and no ReticulumSwift object ever runs there. Neither dependency object nor its frameworks build file is shared with an app target.
- Building `ColumbaNetworkExtension` separately can be useful for diagnosis, but it is not the canonical Model B build path.

## Project maintenance

`support/isolate-modelb-targets.rb` is the authoritative reconciler for targets, schemes, source/resource/framework ownership, runtime conditions, tests, dependencies, extension embedding, and Python packaging isolation.

- `support/configure-xcodeproj.rb` and `support/add-swift-backend-config.rb` are retired fail-closed entry points.
- `support/embed-ne.rb` delegates to the authoritative reconciler; it never attaches the extension to `ColumbaApp`.
- `support/add-ne-backend-deps.rb` is intentionally narrow and maintains native package products only on `ColumbaNetworkExtension`.

## Subsystem deep-dives

- [Model B — Background LXMF Delivery](docs/MODEL_B_BACKGROUND_DELIVERY.md) — experimental Network Extension topology, IPC, lifecycle, invariants, and historical on-device evidence. Model B is not included in the shipping artifact.

## Generated module graph

Regenerate the Mermaid block from the current `Package.swift` and `Columba.xcodeproj/project.pbxproj` with:

```sh
ruby support/generate-module-graph.rb
```

The script reads Xcode targets and target/package-product dependencies through the `xcodeproj` Ruby gem, plus SPM targets through `swift package dump-package`. It overwrites only the block between the marker comments below. Do not edit that block by hand; changes are lost on regeneration.

Reading the graph: edges show Xcode target dependencies, declared `packageProductDependencies`, or Swift package target dependencies. A package-product edge does not necessarily mean a linked framework. In particular `ColumbaNetworkExtension --> ReticulumSwift` is a compile-time declaration only (it satisfies `import ReticulumSwift` in shared files compiled into the NE) - ReticulumSwift is absent from the NE's frameworks build phase, so it is not linked into the extension binary. The NE's actual node engine is embedded-Python RNS (see the Model B deep-dive).

## Target Graph

<!-- module-graph-start -->
```mermaid
flowchart TD
    ColumbaApp["ColumbaApp"]
    ColumbaModelBApp["ColumbaModelBApp"]
    ColumbaNetworkExtension["ColumbaNetworkExtension"]
    LXMFSwift["LXMFSwift"]
    LXSTSwift["LXSTSwift"]
    MapLibre["MapLibre"]
    RNSAPI["RNSAPI"]
    RNSAPITests["RNSAPITests"]
    ReticulumSwift["ReticulumSwift"]
    SwiftBLEBridge["SwiftBLEBridge"]
    ColumbaApp --> LXMFSwift
    ColumbaApp --> LXSTSwift
    ColumbaApp --> MapLibre
    ColumbaApp --> RNSAPI
    ColumbaApp --> ReticulumSwift
    ColumbaApp --> SwiftBLEBridge
    ColumbaModelBApp --> ColumbaNetworkExtension
    ColumbaModelBApp --> LXMFSwift
    ColumbaModelBApp --> LXSTSwift
    ColumbaModelBApp --> MapLibre
    ColumbaModelBApp --> RNSAPI
    ColumbaModelBApp --> ReticulumSwift
    ColumbaModelBApp --> SwiftBLEBridge
    ColumbaNetworkExtension --> LXMFSwift
    ColumbaNetworkExtension --> ReticulumSwift
    RNSAPITests --> RNSAPI
    SwiftBLEBridge --> RNSAPI
    classDef app       fill:#1f6feb,stroke:#0d419d,color:#fff
    classDef extension fill:#8957e5,stroke:#553098,color:#fff
    classDef bridge    fill:#f0883e,stroke:#9e4c0f,color:#fff
    classDef spm_lib   fill:#3fb950,stroke:#0f7a2e,color:#fff
    classDef c_lib     fill:#6e7681,stroke:#30363d,color:#fff
    class ColumbaApp,ColumbaModelBApp app
    class LXMFSwift,LXSTSwift,MapLibre,RNSAPI,RNSAPITests,ReticulumSwift,SwiftBLEBridge spm_lib
    class ColumbaNetworkExtension extension
```
<!-- module-graph-end -->
