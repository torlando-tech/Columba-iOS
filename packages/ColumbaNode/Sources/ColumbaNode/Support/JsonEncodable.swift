//
//  JsonEncodable.swift
//  ColumbaNode
//
//  The protocol types adopt to expose their canonical JSON value. The canonical
//  encoder (JsonValue.canonicalData) is the single consumer; nothing else builds
//  command digests.
//

import Foundation

public protocol JsonEncodable: Sendable {
    var jsonValue: JsonValue { get }
}

extension JsonEncodable {
    /// Canonical RFC 8785 UTF-8 bytes of this value.
    public var canonicalData: Data { jsonValue.canonicalData() }
    /// SHA-256 over the canonical bytes (lowercase hex).
    public var canonicalDigest: Digest {
        Digest(data: SHA256.digest(canonicalData))
    }
}
