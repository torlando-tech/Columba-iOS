//
//  PeerChildInterfaceRegistryTests.swift
//  ColumbaAppTests
//

import XCTest
@testable import ColumbaApp

final class PeerChildInterfaceRegistryTests: XCTestCase {
    func testEmptyRegistryReportsNoIds() {
        let r = PeerChildInterfaceRegistry()
        XCTAssertFalse(r.contains("a"))
        XCTAssertFalse(r.contains(""))
    }

    func testRecordThenContains() {
        let r = PeerChildInterfaceRegistry()
        r.record("peer-1")
        XCTAssertTrue(r.contains("peer-1"))
        XCTAssertFalse(r.contains("peer-2"))
    }

    func testRecordIsIdempotent() {
        let r = PeerChildInterfaceRegistry()
        r.record("peer-1")
        r.record("peer-1")
        r.record("peer-1")
        XCTAssertTrue(r.contains("peer-1"))
    }

    /// Concurrent record / contains stress: with the lock-protected
    /// implementation, a record committed before a contains query (in
    /// wall-clock order) must always be visible to the query, regardless
    /// of how many other writers / readers are running. This is what
    /// load-bears the AppServices peer-child attribution: the connected
    /// closure's contains() must see the record committed by the
    /// peer-spawned closure.
    func testConcurrentRecordAndContainsObservesAllPriorRecords() async {
        let r = PeerChildInterfaceRegistry()
        let count = 1000

        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<count {
                group.addTask {
                    r.record("id-\(i)")
                }
            }
            // Readers running interleaved — should never crash, never
            // observe a partial state.
            for i in 0..<count {
                group.addTask {
                    _ = r.contains("id-\(i)")
                }
            }
        }

        // After all writers complete, every id must be present.
        for i in 0..<count {
            XCTAssertTrue(r.contains("id-\(i)"), "missing id-\(i) after concurrent record")
        }
    }

    /// Per-callback ordering guarantee that load-bears the AppServices
    /// attribution: a record committed synchronously must be visible to
    /// a subsequent contains() on the same thread, with no suspension
    /// or memory barrier needed beyond what the lock provides.
    func testRecordVisibleToImmediateContains() {
        let r = PeerChildInterfaceRegistry()
        r.record("peer-x")
        XCTAssertTrue(r.contains("peer-x"))
    }

    func testResetClears() {
        let r = PeerChildInterfaceRegistry()
        r.record("a")
        r.record("b")
        r.reset()
        XCTAssertFalse(r.contains("a"))
        XCTAssertFalse(r.contains("b"))
    }
}
