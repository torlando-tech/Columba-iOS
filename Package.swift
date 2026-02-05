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
        .package(path: "../LXMFSwift"),
    ],
    targets: [
        .executableTarget(
            name: "ColumbaApp",
            dependencies: ["LXMFSwift"],
            path: "Sources/ColumbaApp"
        )
    ]
)
