import Foundation
import RNSAPI

/// The local RNS identity, as the Python bridge sees it after a successful
/// `PythonBridge.start(...)`. Hashes are hex strings (16-byte truncated form,
/// 32 hex chars) for ease of display + comparison; the raw 64-byte private key
/// stays in Keychain, never in this struct.
///
/// `identityHash` is the hash of the public-key blob; `destinationHash` is the
/// derived hash for `<identity>.lxmf.delivery` (what other peers send messages to).
public struct PyLocalIdentity: Equatable, Sendable {
    public let identityHash: String
    public let destinationHash: String

    public init(identityHash: String, destinationHash: String) {
        self.identityHash = identityHash
        self.destinationHash = destinationHash
    }
}
