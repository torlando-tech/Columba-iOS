// swift-tools-version: 5.9
import PackageDescription

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
        )
    ],
    dependencies: [
        // reticulum-swift, LXMF-swift, and LXST-swift were removed when
        // Columba iOS moved to canonical Mark Qvist Python RNS + LXMF
        // embedded via BeeWare's Python-Apple-support. See the migration
        // plan at /Users/tyler/.claude/plans/okay-please-explore-this-spicy-cloud.md
        // and the PoC at /Users/tyler/repos/columba-python-poc/.
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", from: "6.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "ColumbaApp",
            dependencies: [
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ],
            path: "Sources/ColumbaApp"
        )
    ]
)
