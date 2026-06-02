import Foundation
import Security
import CryptoKit

/// A Reticulum identity.
///
/// **v1 compatibility shape.** Long-term this becomes the pure-data Android
/// `rns-api/model/Identity` (just `hash`/`publicKey`/`privateKey: Data`) with
/// all crypto operations exposed via `RNSCore.sign/verify/encrypt/decrypt`.
/// For now we preserve the AI-Swift surface so the existing 28 call sites
/// in Columba iOS don't all need rewriting in one go.
///
/// Wire format is the canonical RNS 64-byte raw private-key blob (32 bytes
/// X25519 encryption + 32 bytes Ed25519 signing). On disk we additionally
/// support a 128-byte format that includes the corresponding public keys
/// for forward-compat with the AI-Swift exporter — public keys are derived
/// when only the 64-byte form is present.
public struct Identity: Equatable, Sendable {
    /// Identity hash — `SHA-256(publicKeys)` truncated to 16 bytes.
    public let hash: Data

    /// 64-byte concatenated public key blob (32 X25519 + 32 Ed25519).
    public let publicKeys: Data

    /// 64-byte concatenated private key blob (32 X25519 + 32 Ed25519). `nil`
    /// for peer identities recalled from announces; set for the local
    /// identity the user controls.
    public let privateKeyBytes: Data?

    // MARK: - Initializers

    /// Generate a fresh identity. Private + public keys are derived via
    /// CryptoKit; the hash is derived from the public-key blob.
    public init() {
        let x25519 = Curve25519.KeyAgreement.PrivateKey()
        let ed25519 = Curve25519.Signing.PrivateKey()

        let encPriv = x25519.rawRepresentation
        let sigPriv = ed25519.rawRepresentation
        let encPub  = x25519.publicKey.rawRepresentation
        let sigPub  = ed25519.publicKey.rawRepresentation

        self.privateKeyBytes = encPriv + sigPriv
        self.publicKeys = encPub + sigPub
        self.hash = Identity.deriveHash(fromPublicKeys: encPub + sigPub)
    }

    /// Load identity from a 64-byte private-key blob (canonical RNS format).
    public init(privateKeyBytes: Data) throws {
        guard privateKeyBytes.count == 64 else {
            throw IdentityError.invalidPrivateKeyLength(privateKeyBytes.count)
        }
        let encPriv = privateKeyBytes.prefix(32)
        let sigPriv = privateKeyBytes.suffix(32)

        let x25519 = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: encPriv)
        let ed25519 = try Curve25519.Signing.PrivateKey(rawRepresentation: sigPriv)

        let encPub = x25519.publicKey.rawRepresentation
        let sigPub = ed25519.publicKey.rawRepresentation

        self.privateKeyBytes = Data(privateKeyBytes)
        self.publicKeys = encPub + sigPub
        self.hash = Identity.deriveHash(fromPublicKeys: encPub + sigPub)
    }

    /// Construct from a 64-byte public-key blob (no private keys — peer identity).
    public init(publicKeyBytes: Data) throws {
        guard publicKeyBytes.count == 64 else {
            throw IdentityError.invalidPublicKeyLength(publicKeyBytes.count)
        }
        self.privateKeyBytes = nil
        self.publicKeys = publicKeyBytes
        self.hash = Identity.deriveHash(fromPublicKeys: publicKeyBytes)
    }

    /// Memberwise init for use by the bridge when reconstructing from Python state.
    public init(hash: Data, publicKeys: Data, privateKeyBytes: Data?) {
        self.hash = hash
        self.publicKeys = publicKeys
        self.privateKeyBytes = privateKeyBytes
    }

    // MARK: - Hex helpers

    /// Lowercase hex of `hash`. e.g. `"a85afbd4342415caa45d29799d6f950e"`.
    public var hexHash: String { hash.toHex() }

    /// Lowercase hex of `publicKeys`. Used by the AI Swift `Identity(_:String)`
    /// recall form — preserved for call-site compatibility.
    public var publicKeyHex: String { publicKeys.toHex() }

    public var hasPrivateKeys: Bool { privateKeyBytes != nil }

    // MARK: - Derivation

    /// Canonical RNS truncated-SHA256 hash of the public-key blob.
    public static func deriveHash(fromPublicKeys publicKeys: Data) -> Data {
        Data(SHA256.hash(data: publicKeys)).prefix(16)
    }

    /// Export raw 64-byte private-key blob. Throws if no private keys.
    public func exportPrivateKeys() throws -> Data {
        guard let pk = privateKeyBytes else { throw IdentityError.noPrivateKeys }
        return pk
    }

    // MARK: - Keychain

    /// Save the 64-byte private-key blob to Keychain under the given
    /// service / account. Caller-supplied service+account keys let
    /// `IdentityManager` namespace per-identity entries.
    public func saveToKeychain(service: String, account: String, accessGroup: String? = nil) throws {
        guard let pk = privateKeyBytes else { throw IdentityError.noPrivateKeys }
        var baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Shared keychain group so the app + Network Extension resolve the SAME item.
        if let accessGroup { baseQuery[kSecAttrAccessGroup as String] = accessGroup }
        let attrs: [String: Any] = baseQuery.merging([
            kSecValueData as String: pk,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: pk]
            let upStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard upStatus == errSecSuccess else {
                throw IdentityError.keychainWriteFailed(upStatus)
            }
        } else if status != errSecSuccess {
            throw IdentityError.keychainWriteFailed(status)
        }
    }

    /// Load identity from Keychain. Returns `nil` if no item is stored at
    /// the (service, account) pair.
    public static func loadFromKeychain(service: String, account: String, accessGroup: String? = nil) throws -> Identity? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try Identity(privateKeyBytes: data)
        case errSecItemNotFound:
            return nil
        default:
            throw IdentityError.keychainReadFailed(status)
        }
    }

    @discardableResult
    public static func deleteFromKeychain(service: String, account: String, accessGroup: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

public enum IdentityError: Error, LocalizedError {
    case invalidPrivateKeyLength(Int)
    case invalidPublicKeyLength(Int)
    case noPrivateKeys
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case cryptoUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKeyLength(let n):
            return "Invalid private key length: \(n) (expected 64)"
        case .invalidPublicKeyLength(let n):
            return "Invalid public key length: \(n) (expected 64)"
        case .noPrivateKeys:
            return "Identity has no private keys"
        case .keychainReadFailed(let s):
            return "Keychain read failed (\(s))"
        case .keychainWriteFailed(let s):
            return "Keychain write failed (\(s))"
        case .cryptoUnsupported(let op):
            return "Crypto operation '\(op)' is not implemented in v1 — comes back in Phase 2 via RNSCore"
        }
    }
}
