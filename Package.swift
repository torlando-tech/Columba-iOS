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
        .package(path: "../LXMF-swift"),
        .package(path: "../LXST-swift"),
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", from: "6.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "ColumbaApp",
            dependencies: [
                .product(name: "LXMFSwift", package: "LXMF-swift"),
                .product(name: "LXSTSwift", package: "LXST-swift"),
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ],
            path: "Sources/ColumbaApp"
        )
    ]
)
