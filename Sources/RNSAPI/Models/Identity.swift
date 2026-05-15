import Foundation

/// A Reticulum identity, as seen by the protocol layer.
///
/// - `hash`: 16-byte truncated SHA-256 of the public-key blob — the
///   addressable identity hash used in destination derivation and announce
///   filtering. Display as lowercase hex.
/// - `publicKey`: the full 64-byte public-key blob (32 X25519 + 32 Ed25519).
///   Used by peers to encrypt to / verify signatures from this identity.
/// - `privateKey`: the 64-byte private-key blob (32 X25519 + 32 Ed25519).
///   `nil` for identities recalled from announces (peer identities); set
///   only for the local identity that the user controls.
///
/// Mirrors `Identity.kt` in Columba Android's `rns-api/model`.
public struct Identity: Equatable, Sendable {
    public let hash: Data
    public let publicKey: Data
    public let privateKey: Data?

    public init(hash: Data, publicKey: Data, privateKey: Data?) {
        self.hash = hash
        self.publicKey = publicKey
        self.privateKey = privateKey
    }

    /// Convenience: lowercase hex of `hash`.
    public var hashHex: String { hash.toHex() }
}
