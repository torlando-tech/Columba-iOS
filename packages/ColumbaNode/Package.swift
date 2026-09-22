// swift-tools-version: 5.9
import PackageDescription

//
// ColumbaNode — the durable app/NE seam backbone for the node-service v1 contract
// (.scratch/ne-node-contract).
//
// This local package is the ENGINE-AGNOSTIC core that both the app (the typed
// facade / shared-store reader) and the Network Extension (the node owner /
// engine adapter) link. It contains:
//
//   • the IDL common type system (distinct UUID/hex/counter wrappers)
//   • RFC 8785 canonical encoding + SHA-256 (the ONE place command digests are
//     produced — contract 3)
//   • the durable command records (Intent / Command / receipts / ledger)
//   • the shared SQLite store + command ledger + stage-first admission rules
//
// It deliberately contains NO protocol engine. The Python RNS engine (and later
// Reticulum-Go / microReticulum) plugs in behind the engine-adapter seam
// (contract 15); this package only defines the durable, canonical contract.
//
// Pure Swift + system sqlite3, so it builds and tests on both Linux and Darwin.
//
let package = Package(
    name: "ColumbaNode",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ColumbaNode", targets: ["ColumbaNode"]),
    ],
    targets: [
        // System sqlite3 via a C target whose include/ holds a `[system]`
        // modulemap (header + `link "sqlite3"`). A C target (vs .systemLibrary)
        // puts include/ on the search path so `import SQLite3Shim` resolves in the
        // Swift importer on both Linux and Darwin.
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
        .testTarget(
            name: "ColumbaNodeTests",
            dependencies: ["ColumbaNode"],
            path: "Tests/ColumbaNodeTests"
        ),
    ]
)
