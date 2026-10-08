import XCTest
import Foundation
@testable import ColumbaNode

/// Locks the canonical encoding + SHA-256 to the contract's reference vector
/// (examples.json). If this passes, the Swift module and the reference agree
/// byte-for-byte on the one staged submitMessage intent the contract publishes.
final class CanonicalDigestTests: XCTestCase {

    // The exact values from .scratch/ne-node-contract/docs/contracts/examples.json.
    private let storeEpoch = "11111111-1111-4111-8111-111111111111"
    private let commandID  = "44444444-4444-4444-8444-444444444444"
    private let identityID = "33333333-3333-4333-8333-333333333333"
    private let destination = "0123456789abcdef0123456789abcdef"
    private let expectedDigest = "952cb4131c408b2831f2b2188ffd3300df2f50ec1a49c28af6b4bdeea90c86ec"

    private func makeIntent() throws -> Intent {
        let intent = Intent(
            storeEpoch: try XCTUnwrap(StoreEpoch(wire: storeEpoch)),
            commandID: try XCTUnwrap(CommandID(wire: commandID)),
            createdAt: Instant(1790000000000),
            expiresAt: nil,
            afterCommandID: nil,
            body: .submitMessage(submit: SubmitMessage(
                scope: Scope(identityID: try XCTUnwrap(IdentityID(wire: identityID))),
                destination: try XCTUnwrap(DestinationHash(hex: destination)),
                payload: .chat(ChatPayload(title: nil, content: "Hello from Columba")),
                delivery: DeliveryPolicy(preferred: .automatic, allowPropagationFallback: false,
                                         maxAttempts: NonNegative(3), stampBudgetMs: NonNegative(5000)),
                deadline: Instant(1790086400000)
            ))
        )
        return intent
    }

    func testContractVectorDigest() throws {
        let intent = try makeIntent()
        let data = intent.canonicalData
        let canonicalStr = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(data.sha256Hex, expectedDigest,
                       "Swift canonical digest must match the contract reference vector. canonical:\n\(canonicalStr)")
    }

    func testCanonicalFormMatchesExamplesJson() throws {
        let intent = try makeIntent()
        let canonicalData = intent.canonicalData
        let canonical = String(decoding: canonicalData, as: UTF8.self)
        // Spot-check key ordering + null materialization from the published vector.
        XCTAssertTrue(canonical.hasPrefix("{"), "canonical must start with {")
        XCTAssertTrue(canonical.contains("\"afterCommandID\":null"), "absent optional must be explicit null")
        // object keys are canonically sorted: afterCommandID < body < commandID < createdAt < expiresAt < storeEpoch
        let order = ["\"afterCommandID\"", "\"body\"", "\"commandID\"", "\"createdAt\"", "\"expiresAt\"", "\"storeEpoch\""]
        var offsets: [String.Index] = []
        for key in order {
            guard let i = canonical.range(of: key)?.lowerBound else {
                XCTFail("missing key \(key) in canonical: \(canonical)"); return
            }
            offsets.append(i)
        }
        // Verify strictly increasing order by distance from start.
        let start = canonical.startIndex
        for k in 0..<(offsets.count - 1) {
            let a = canonical.distance(from: start, to: offsets[k])
            let b = canonical.distance(from: start, to: offsets[k + 1])
            XCTAssertTrue(a < b, "keys out of canonical order: \(canonical) (offsets \(a) >= \(b))")
        }
    }
}
