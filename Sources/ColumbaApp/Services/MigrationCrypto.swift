#if COLUMBA_MIGRATION_ENABLED
//
//  MigrationCrypto.swift
//  ColumbaApp
//
//  AES-256-GCM encryption/decryption with PBKDF2-HMAC-SHA256 key derivation.
//  Matches Android's .columba file header format for cross-platform compatibility.
//
//  File format: [0x02 version][16-byte salt][12-byte nonce][ciphertext + 16-byte GCM tag]
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Errors

enum MigrationCryptoError: Error, LocalizedError {
    case invalidFormat
    case wrongPassword
    case passwordRequired
    case encryptionFailed
    case dataTooShort

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid backup file format"
        case .wrongPassword:
            return "Incorrect password"
        case .passwordRequired:
            return "This backup is encrypted and requires a password"
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .dataTooShort:
            return "Backup file is corrupted or truncated"
        }
    }
}

// MARK: - Migration Crypto

/// Handles AES-256-GCM encryption/decryption of .columba backup files.
///
/// File header format (matching Android):
/// - Byte 0: Version (0x02)
/// - Bytes 1-16: PBKDF2 salt (16 bytes)
/// - Bytes 17-28: AES-GCM nonce/IV (12 bytes)
/// - Bytes 29+: AES-GCM ciphertext with appended 16-byte authentication tag
enum MigrationCrypto {
    // MARK: - Constants

    /// File format version byte.
    private static let formatVersion: UInt8 = 0x02

    /// PBKDF2 iteration count (matches Android).
    private static let pbkdf2Iterations: UInt32 = 600_000

    /// Salt length in bytes.
    private static let saltLength = 16

    /// AES-GCM nonce length in bytes.
    private static let nonceLength = 12

    /// Derived key length (256 bits for AES-256).
    private static let keyLength = 32

    /// Total header size: version(1) + salt(16) + nonce(12) = 29 bytes.
    private static let headerLength = 1 + saltLength + nonceLength

    // MARK: - Public API

    /// Check if data appears to be an encrypted .columba file.
    ///
    /// - Parameter data: Raw file data
    /// - Returns: True if the first byte is the encrypted format version (0x02)
    static func isEncrypted(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data[0] == formatVersion
    }

    /// Check if data appears to be a ZIP file (for Android exports with attachments).
    ///
    /// - Parameter data: Raw file data
    /// - Returns: True if data starts with ZIP magic bytes (PK)
    static func isZip(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0x50 && data[1] == 0x4B
    }

    /// Encrypt data with a password.
    ///
    /// Generates random salt and nonce, derives AES-256 key via PBKDF2,
    /// and encrypts using AES-GCM. Returns data with prepended header.
    ///
    /// - Parameters:
    ///   - data: Plaintext data to encrypt
    ///   - password: User-provided password (minimum 8 characters)
    /// - Returns: Encrypted data with header: [version][salt][nonce][ciphertext+tag]
    /// - Throws: `MigrationCryptoError.encryptionFailed` if encryption fails
    static func encrypt(data: Data, password: String) throws -> Data {
        // Generate random salt and nonce
        var salt = Data(count: saltLength)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }

        var nonceBytes = Data(count: nonceLength)
        nonceBytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, nonceLength, $0.baseAddress!) }

        // Derive key
        let key = try deriveKey(password: password, salt: salt)

        // Encrypt with AES-GCM
        let symmetricKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce)

        // Build output: version + salt + nonce + ciphertext+tag
        var output = Data(capacity: headerLength + sealedBox.ciphertext.count + 16)
        output.append(formatVersion)
        output.append(salt)
        output.append(nonceBytes)
        // sealedBox.ciphertext + sealedBox.tag combined
        output.append(sealedBox.ciphertext)
        output.append(sealedBox.tag)

        return output
    }

    /// Decrypt an encrypted .columba file.
    ///
    /// Extracts salt and nonce from header, derives key via PBKDF2,
    /// and decrypts using AES-GCM.
    ///
    /// - Parameters:
    ///   - data: Encrypted file data (with header)
    ///   - password: User-provided password
    /// - Returns: Decrypted plaintext data
    /// - Throws: `MigrationCryptoError.wrongPassword` if decryption fails (bad tag),
    ///           `MigrationCryptoError.invalidFormat` if header is malformed
    static func decrypt(data: Data, password: String) throws -> Data {
        guard data.count > headerLength + 16 else {
            throw MigrationCryptoError.dataTooShort
        }

        guard data[0] == formatVersion else {
            throw MigrationCryptoError.invalidFormat
        }

        // Extract header components
        let salt = data[1..<(1 + saltLength)]
        let nonceBytes = data[(1 + saltLength)..<headerLength]
        let ciphertextAndTag = data[headerLength...]

        // Derive key
        let key = try deriveKey(password: password, salt: Data(salt))

        // Decrypt
        let symmetricKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)

        // Separate ciphertext and tag (tag is last 16 bytes)
        let tagStart = ciphertextAndTag.endIndex - 16
        let ciphertext = ciphertextAndTag[ciphertextAndTag.startIndex..<tagStart]
        let tag = ciphertextAndTag[tagStart...]

        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )

        do {
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw MigrationCryptoError.wrongPassword
        }
    }

    // MARK: - Key Derivation

    /// Derive a 256-bit key from password and salt using PBKDF2-HMAC-SHA256.
    ///
    /// - Parameters:
    ///   - password: User password (UTF-8 encoded)
    ///   - salt: Random salt bytes
    /// - Returns: 32-byte derived key
    private static func deriveKey(password: String, salt: Data) throws -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: keyLength)

        let status = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw MigrationCryptoError.encryptionFailed
        }

        return derivedKey
    }
}
#endif
