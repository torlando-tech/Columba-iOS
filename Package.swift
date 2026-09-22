// swift-tools-version: 5.9
import PackageDescription

// Module layout — the iOS app is Xcode-built (Columba.xcodeproj), with
// configure-xcodeproj.rb pulling files in by path. This SwiftPM manifest
// exists for two reasons:
//
//   1. The Xcode project references this manifest as a LOCAL package
//      (XCLocalSwiftPackageReference) so RNSAPI / SwiftBLEBridge get built by
//      SwiftPM rather than hand-written pbxproj entries.
//   2. `swift build` (used by tooling + CI) can still typecheck the pure-Swift
//      libraries without the Python.xcframework bridging header.
//
// The LXST voice stack (LXSTSwift + the Opus/Codec2 codec C trees) is no longer
// vendored here — it lives in the standalone, transport-agnostic LXST-swift
// package (consumed via SwiftPM, wired to RNS through Columba's
// PythonNetworkTransport). See `dependencies` below.
//
// Targets that DO require the bridging header (PythonBridge, RNSBackendPy,
// ColumbaApp) live ONLY in the pbxproj — they're not declared here.
let package = Package(
    name: "ColumbaApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RNSAPI", targets: ["RNSAPI"]),
        .library(name: "SwiftBLEBridge", targets: ["SwiftBLEBridge"]),
        // Durable app/NE seam backbone for the node-service v1 contract
        // (.scratch/ne-node-contract). Engine-agnostic: canonical encoding,
        // stage-first durable admission, the bounded control channel, and the
        // NodeEngine adapter. Both the app (typed facade) and the NE (node
        // owner) link this. No protocol engine in here - Python RNS /
        // Reticulum-Go / microReticulum plug in behind the engine-adapter seam.
        .library(name: "ColumbaNode", targets: ["ColumbaNode"]),
    ],
    dependencies: [
        // Transport-agnostic LXST voice library (owns the Opus/Codec2 codecs
        // and the NetworkTransport seam; no Reticulum dependency). Columba
        // provides the implementation via PythonNetworkTransport. Tracking the
        // branch until a release is tagged — same model as the RNS fork.
        .package(url: "https://github.com/torlando-tech/LXST-swift.git", branch: "feat/transport-agnostic"),
    ],
    targets: [
        // ──────── RNSAPI: pure-interface protocol surface ────────
        .target(
            name: "RNSAPI",
            path: "Sources/RNSAPI",
            // libsqlite3 (system) backs LXMFDatabase's on-disk persistence.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // ──────── ColumbaNode: durable app/NE seam (node-service v1) ────────
        // System sqlite3 via a C target whose include/ exposes a clang module
        // (header + `link "sqlite3"`); a C target puts include/ on the search
        // path so `import SQLite3Shim` resolves on both Linux and Darwin.
        .target(
            name: "SQLite3Shim",
            path: "Sources/SQLite3Shim",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "ColumbaNode",
            dependencies: ["SQLite3Shim"],
            path: "Sources/ColumbaNode",
            resources: []
        ),

        // ──────── SwiftBLEBridge: CoreBluetooth wrapper for ble-reticulum ──
        // Mirror of Columba Android's reticulum/ble module. Holds CBCentralManager
        // + CBPeripheralManager state and exposes a Swift API that the iOS BLE
        // driver (app/ble/ios_ble_driver.py) calls into. The Python ↔ Swift
        // callback invocation path lives separately in the pbxproj-only
        // `PythonBLECallbackBridge.swift` (which needs Python.h); SwiftBLEBridge
        // itself is pure CoreBluetooth so `swift build` compiles it cleanly.
        .target(
            name: "SwiftBLEBridge",
            dependencies: ["RNSAPI"],
            path: "Sources/SwiftBLEBridge"
        ),
        // Pure-Swift unit tests for RNSAPI (msgpack, AppDataParser,
        // PropagationNodeInfo). Runs natively via `swift test` on macOS — no
        // simulator / Xcode test target needed (RNSAPI has no UIKit/Python deps).
        .testTarget(
            name: "RNSAPITests",
            dependencies: ["RNSAPI"],
            path: "Tests/RNSAPITests"
        ),
        .testTarget(
            name: "SwiftBLEBridgeTests",
            dependencies: ["SwiftBLEBridge"],
            path: "Tests/SwiftBLEBridgeTests"
        ),
        .testTarget(
            name: "ColumbaNodeTests",
            dependencies: ["ColumbaNode"],
            path: "Tests/ColumbaNodeTests"
        ),
    ]
)
