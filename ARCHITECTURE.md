# Columba-iOS Architecture

Target / module dependency graph for the iOS app. Mirrors the role of `docs/architecture.md` in the sibling Android repo (`columba/`).

## Subsystem deep-dives

- [Model B — Background LXMF Delivery](docs/MODEL_B_BACKGROUND_DELIVERY.md) — how the Network Extension delivers LXMF messages + notifications while the app is backgrounded/suspended/locked (no APNS): the NE-canonical node, the control IPC + App-Group frame bridge, the load-bearing invariants, and the on-device-verified inbound/outbound/announce flows.

Regenerate this file from the current `Package.swift` + `Columba.xcodeproj/project.pbxproj`:

```sh
ruby support/generate-module-graph.rb
```

The script reads:
- pbxproj targets (e.g. `ColumbaApp`, `ColumbaNetworkExtension`, `PythonBridge`, `RNSBackendPy`) via the `xcodeproj` Ruby gem (already a dependency for `support/configure-xcodeproj.rb`).
- SPM targets (e.g. `RNSAPI`, `LXSTSwift`, `COpus`, `CCodec2`, `SwiftBLEBridge`) via `swift package dump-package`.

It overwrites the Mermaid block between the start/end marker comments below the `## Target Graph` heading. Do not edit between the markers by hand — changes will be lost on next regen.

## Target Graph

<!-- module-graph-start -->
```mermaid
flowchart TD
    CCodec2["CCodec2"]
    COpus["COpus"]
    ColumbaApp["ColumbaApp"]
    ColumbaNetworkExtension["ColumbaNetworkExtension"]
    LXSTSwift["LXSTSwift"]
    MapLibre["MapLibre"]
    RNSAPI["RNSAPI"]
    SwiftBLEBridge["SwiftBLEBridge"]
    ColumbaApp --> LXSTSwift
    ColumbaApp --> MapLibre
    ColumbaApp --> RNSAPI
    ColumbaApp --> SwiftBLEBridge
    LXSTSwift --> CCodec2
    LXSTSwift --> COpus
    LXSTSwift --> RNSAPI
    SwiftBLEBridge --> RNSAPI
    classDef app       fill:#1f6feb,stroke:#0d419d,color:#fff
    classDef extension fill:#8957e5,stroke:#553098,color:#fff
    classDef bridge    fill:#f0883e,stroke:#9e4c0f,color:#fff
    classDef spm_lib   fill:#3fb950,stroke:#0f7a2e,color:#fff
    classDef c_lib     fill:#6e7681,stroke:#30363d,color:#fff
    class ColumbaApp app
    class LXSTSwift,MapLibre,RNSAPI,SwiftBLEBridge spm_lib
    class ColumbaNetworkExtension extension
    class CCodec2,COpus c_lib
```
<!-- module-graph-end -->
