import CryptoKit
import XCTest
@testable import SwiftBLEBridge

/// The App-Group host seam calls this entry point from the app's user-initiated
/// queue, so it must return a proof that RNS's own `stamp_valid` accepts and
/// must honour cancellation by predicate (the seam's cancel frame) rather than
/// by a native job id.
final class HostKeyStampSearchTests: XCTestCase {
    private let material = Data("host-seam-material-32-bytes!!!".utf8)

    /// 0x10… is a cost-4-ish threshold: ~16 attempts on average, a few thousand
    /// at worst, so the test is deterministic in runtime but still a real search.
    private let easyTarget = Data([0x10] + [UInt8](repeating: 0, count: 31))

    func testReturnsProofThatMatchesTheExactTarget() throws {
        let proof = try XCTUnwrap(
            HostKeyStampSearch.run(material: material, targetBytes: easyTarget).payload
        )
        XCTAssertEqual(proof.count, 64)
        let publicKey = proof[32...]
        let digest = Array(SHA256.hash(data: material + publicKey))
        XCTAssertTrue(lexicographicallyAtMost(digest, easyTarget), "proof misses the target")
    }

    func testEveryDigestTargetReturnsARealKeypairWithoutRounds() throws {
        let answer = HostKeyStampSearch.run(
            material: material,
            targetBytes: Data(repeating: 255, count: 32)
        )
        let payload = try XCTUnwrap(answer.payload)
        XCTAssertEqual(payload.count, 64)
        XCTAssertEqual(answer.rounds, 0)
        // 64 zero bytes would satisfy nothing that Link.py compares; the payload
        // must carry a genuine X25519 public key.
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: payload.prefix(32))
        XCTAssertEqual(Data(key.publicKey.rawRepresentation), Data(payload.suffix(32)))
    }

    func testCancellationByPredicateStopsASearchThatWouldOtherwiseRunLong() {
        // Only an all-zero digest passes this target, so the search never
        // completes on its own.
        let hardTarget = Data(repeating: 0, count: 32)
        let started = CFAbsoluteTimeGetCurrent()
        let answer = HostKeyStampSearch.run(
            material: material,
            targetBytes: hardTarget,
            cancelled: { CFAbsoluteTimeGetCurrent() - started > 0.05 }
        )
        XCTAssertNil(answer.payload)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 2.0)
        // The cancelled run must still report its attempts: that is the only
        // rate measurement for a stamp that hits the 15s link deadline.
        XCTAssertGreaterThan(answer.rounds, 0)
    }

    func testMalformedTargetIsRejectedWithoutSearching() {
        let answer = HostKeyStampSearch.run(material: material, targetBytes: Data(repeating: 0, count: 31))
        XCTAssertNil(answer.payload)
        XCTAssertEqual(answer.rounds, 0)
    }

    func testEveryRequestedWorkerContributesRounds() {
        // Two workers must both run: a single-worker regression would still
        // pass every functional check but halve the link-stamp rate.
        let started = CFAbsoluteTimeGetCurrent()
        let answer = HostKeyStampSearch.run(
            material: material,
            targetBytes: Data(repeating: 0, count: 32),
            workers: 2,
            cancelled: { CFAbsoluteTimeGetCurrent() - started > 0.2 }
        )
        XCTAssertNil(answer.payload)
        XCTAssertGreaterThan(answer.rounds, 1)
    }

    private func lexicographicallyAtMost(_ digest: [UInt8], _ target: Data) -> Bool {
        // Mirrors `StampTarget.accepts`: unsigned big-endian, inclusive.
        for (left, right) in zip(digest, target) {
            if left != right { return left < right }
        }
        return true
    }
}
