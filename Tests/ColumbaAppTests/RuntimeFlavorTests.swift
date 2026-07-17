//
//  RuntimeFlavorTests.swift
//  ColumbaAppTests
//
//  Compile-time contract tests for the mutually exclusive shipping-Python and
//  experimental-Model-B app targets.
//

import XCTest
@testable import ColumbaApp

#if COLUMBA_RUNTIME_PYTHON && COLUMBA_RUNTIME_MODEL_B
#error("A test host must select exactly one Columba runtime flavor")
#endif

final class RuntimeFlavorTests: XCTestCase {
    func testActiveFlavorMatchesHostConfiguration() {
        #if COLUMBA_RUNTIME_MODEL_B
        XCTAssertEqual(BackendPreference.runtimeFlavor, .modelB)
        #elseif COLUMBA_RUNTIME_PYTHON
        XCTAssertEqual(BackendPreference.runtimeFlavor, .python)
        #else
        XCTFail("The ColumbaAppTests target must declare its host runtime flavor")
        #endif
    }

    func testExactlyOneCompileTimeFlavorIsActive() {
        #if COLUMBA_RUNTIME_PYTHON
        let pythonFlavorCount = 1
        #else
        let pythonFlavorCount = 0
        #endif

        #if COLUMBA_RUNTIME_MODEL_B
        let modelBFlavorCount = 1
        #else
        let modelBFlavorCount = 0
        #endif

        XCTAssertEqual(
            pythonFlavorCount + modelBFlavorCount,
            1,
            "A test host must select exactly one runtime flavor"
        )
    }

    #if COLUMBA_RUNTIME_PYTHON
    func testPersistedSwiftPreferenceCannotChangeShippingRuntime() {
        let suiteName = "test.RuntimeFlavor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "useSwiftBackend")

        XCTAssertEqual(BackendPreference.runtimeFlavor(defaults: defaults), .python)
    }
    #endif
}
