// swift-tools-version: 5.9
import PackageDescription

// Module layout mirrors Columba Android's `feat/rns-dual-build` branch
// (rns-api / rns-backend-py / app). iOS only ships the Python backend, so
// there's no rns-backend-kt equivalent. See the migration plan at
// /Users/tyler/.claude/plans/okay-please-explore-this-spicy-cloud.md.
//
//   PythonBridge   raw CPython embedding — runtime + GIL + bridging header
//   RNSAPI         pure-interface module: RNSBackend protocol + sub-protocols
//                  + value-type models + utility helpers. Mirrors rns-api/.
//   RNSBackendPy   Python implementation of RNSAPI, wraps PythonBridge.
//                  Mirrors rns-backend-py/.
//   ColumbaApp     existing UI; imports only RNSAPI; instantiates
//                  RNSBackendPy at startup.
let package = Package(
    name: "ColumbaApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ColumbaApp",
            targets: ["ColumbaApp"]
        ),
        .library(name: "RNSAPI", targets: ["RNSAPI"]),
        .library(name: "RNSBackendPy", targets: ["RNSBackendPy"]),
        .library(name: "PythonBridge", targets: ["PythonBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", from: "6.9.0"),
    ],
    targets: [
        // ──────── PythonBridge: raw CPython embedding ────────
        .target(
            name: "PythonBridge",
            path: "Sources/PythonBridge",
            // The bridging header is consumed by Xcode's app target; SwiftPM
            // builds this target with `import Python` resolving via the
            // Python.xcframework added to the Xcode project. Header is
            // exposed here just so the file lives in version control.
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),

        // ──────── RNSAPI: pure-interface protocol surface ────────
        .target(
            name: "RNSAPI",
            path: "Sources/RNSAPI"
        ),

        // ──────── RNSBackendPy: Python-backed RNSAPI impls ────────
        .target(
            name: "RNSBackendPy",
            dependencies: ["RNSAPI", "PythonBridge"],
            path: "Sources/RNSBackendPy"
        ),

        // ──────── ColumbaApp: SwiftUI + ViewModels + Services ────────
        .executableTarget(
            name: "ColumbaApp",
            dependencies: [
                "RNSAPI",
                "RNSBackendPy",
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ],
            path: "Sources/ColumbaApp"
        )
    ]
)
