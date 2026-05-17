// swift-tools-version: 5.9
import PackageDescription

// Module layout — the iOS app is Xcode-built (Columba.xcodeproj), with
// configure-xcodeproj.rb pulling files in by path. This SwiftPM manifest
// exists for two reasons:
//
//   1. The Xcode project references this manifest as a LOCAL package
//      (XCLocalSwiftPackageReference) so the lxst-swift / COpus / CCodec2
//      C source tree gets compiled by SwiftPM rather than by hand-written
//      pbxproj entries for ~380 individual C files.
//   2. `swift build` (used by tooling + CI) can still typecheck the pure-
//      Swift libraries (RNSAPI, LXSTSwift) without the Python.xcframework
//      bridging header that Python's C API requires.
//
// Targets that DO require the bridging header (PythonBridge, RNSBackendPy,
// ColumbaApp) live ONLY in the pbxproj — they're not declared here. Adding
// them would trigger Xcode's "local package" wiring to try to compile them
// with SwiftPM (no bridging header → "cannot find type 'PyObject'").
let package = Package(
    name: "ColumbaApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RNSAPI", targets: ["RNSAPI"]),
        .library(name: "LXSTSwift", targets: ["LXSTSwift"]),
        .library(name: "SwiftBLEBridge", targets: ["SwiftBLEBridge"]),
    ],
    dependencies: [],
    targets: [
        // ──────── RNSAPI: pure-interface protocol surface ────────
        .target(
            name: "RNSAPI",
            path: "Sources/RNSAPI"
        ),

        // ──────── COpus: libopus 1.5.2, compiled from source ────────
        .target(
            name: "COpus",
            path: "Sources/COpus",
            exclude: [
                "AUTHORS", "COPYING", "ChangeLog", "INSTALL", "NEWS", "README",
                "CMakeLists.txt", "Makefile.am", "Makefile.in", "Makefile.unix", "Makefile.mips",
                "configure", "configure.ac", "config.guess", "config.sub", "config.h.in",
                "aclocal.m4", "compile", "depcomp", "install-sh", "ltmain.sh", "missing", "test-driver",
                "meson.build", "meson_options.txt",
                "opus.m4", "opus.pc.in", "opus-uninstalled.pc.in", "package_version",
                "celt_headers.mk", "celt_sources.mk", "opus_headers.mk", "opus_sources.mk",
                "silk_headers.mk", "silk_sources.mk", "lpcnet_headers.mk", "lpcnet_sources.mk",
                "cmake", "doc", "m4", "meson", "tests", "dnn",
                "celt/arm", "celt/mips", "celt/x86",
                "silk/arm", "silk/mips", "silk/x86",
                "silk/fixed",
                "silk/float/x86",
                "celt/tests", "silk/tests",
                "celt/opus_custom_demo.c",
                "src/opus_demo.c", "src/opus_compare.c", "src/repacketizer_demo.c",
                "celt/meson.build", "silk/meson.build",
                "src/meson.build", "include/meson.build",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("src"),
                .define("OPUS_BUILD"),
                .define("VAR_ARRAYS", to: "1"),
                .define("FLOATING_POINT"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
                .define("HAVE_STDINT_H", to: "1"),
                .define("HAVE_DLFCN_H", to: "1"),
                .define("HAVE_INTTYPES_H", to: "1"),
                .define("HAVE_MEMORY_H", to: "1"),
                .define("HAVE_STDLIB_H", to: "1"),
                .define("HAVE_STRING_H", to: "1"),
            ]
        ),

        // ──────── CCodec2: codec2 1.2.0, compiled from source ────────
        .target(
            name: "CCodec2",
            path: "Sources/CCodec2",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .define("CODEC2_VERSION_MAJOR", to: "1"),
                .define("CODEC2_VERSION_MINOR", to: "2"),
                .define("CODEC2_VERSION_PATCH", to: "0"),
                .define("CODEC2_VERSION", to: "\"1.2.0\""),
                .define("GIT_HASH", to: "\"None\""),
                .define("HAVE_STDLIB_H", to: "1"),
                .define("HAVE_STRING_H", to: "1"),
                .define("SIZEOF_INT", to: "4"),
            ]
        ),

        // ──────── LXSTSwift: Swift LXST state machine + audio + codecs ────────
        // Mirror of Columba Android's lxst-kt. Retargeted from
        // reticulum-swift (deleted in Phase 0) onto an `LXSTLinkTransport`
        // protocol that the application wires to PythonRNSBackend.
        // Deliberately does NOT depend on RNSBackendPy / PythonBridge so
        // that `swift build` (used by tooling + CI) compiles cleanly without
        // the Xcode bridging-header that Python's C API needs.
        .target(
            name: "LXSTSwift",
            dependencies: ["RNSAPI", "COpus", "CCodec2"],
            path: "Sources/LXSTSwift"
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
    ]
)
