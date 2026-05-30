import Foundation

/// Hex string ↔ `Data` extensions used everywhere a destination / identity
/// / packet hash crosses a boundary (logs, JSON keys, dict keys, the
/// Python bridge surface). Lowercase-hex is the canonical wire form across
/// the protocol layer and the UI.
///
/// Centralised here because the toHex / hexToData pair was previously
/// inlined as `bytes.map { String(format: "%02x", $0) }.joined()` in
/// dozens of call sites across the AI-generated `ReticulumSwift` /
/// `LXMFSwift` libraries.
///
/// Mirrors `HexExt.kt` in Columba Android's `rns-api`.
public extension Data {
    /// Lowercase hex representation. e.g. `Data([0x01, 0xAB]).toHex() == "01ab"`.
    func toHex() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

public extension String {
    /// Hex string → `Data`. Caller is responsible for the hex being
    /// even-length and well-formed; throws `HexDecodingError` otherwise.
    /// Mixed case is accepted.
    func hexToData() throws -> Data {
        guard count % 2 == 0 else {
            throw HexDecodingError.oddLength(length: count, sample: String(prefix(32)))
        }
        var data = Data(capacity: count / 2)
        var idx = startIndex
        while idx < endIndex {
            let next = index(idx, offsetBy: 2)
            guard let byte = UInt8(self[idx..<next], radix: 16) else {
                throw HexDecodingError.invalidCharacter(at: distance(from: startIndex, to: idx))
            }
            data.append(byte)
            idx = next
        }
        return data
    }
}

/// Errors thrown by `String.hexToData()`.
public enum HexDecodingError: Error, CustomStringConvertible, Equatable {
    case oddLength(length: Int, sample: String)
    case invalidCharacter(at: Int)

    public var description: String {
        switch self {
        case .oddLength(let length, let sample):
            return "Hex string must have even length: \"\(sample)\" (length=\(length))"
        case .invalidCharacter(let at):
            return "Hex string has non-hex character at index \(at)"
        }
    }
}
