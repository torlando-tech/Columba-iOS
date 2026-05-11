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
        // SPM resolves these from GitHub on every fresh checkout. To work
        // against an in-progress local clone of any of these libraries
        // without committing a path-override, drop a per-machine
        // `.swiftpm/configuration/mirrors.json` mapping the URL to a local
        // directory — see README "Local development against unreleased
        // library changes" for the exact recipe.
        .package(url: "https://github.com/torlando-tech/LXMF-swift.git", from: "0.4.0"),
        .package(url: "https://github.com/torlando-tech/LXST-swift.git", from: "0.2.0"),
        .package(url: "https://github.com/torlando-tech/reticulum-swift.git", from: "0.3.0"),
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", from: "6.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "ColumbaApp",
            dependencies: [
                .product(name: "LXMFSwift", package: "LXMF-swift"),
                .product(name: "LXSTSwift", package: "LXST-swift"),
                // ReticulumSwift is imported directly by several view
                // models (e.g. NomadNetBrowserViewModel,
                // MessagingViewModel) — listed here as a direct product
                // dep so the version constraint on the package above is
                // actually exercised by SPM at resolution time.
                .product(name: "ReticulumSwift", package: "reticulum-swift"),
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ],
            path: "Sources/ColumbaApp"
        )
    ]
)
