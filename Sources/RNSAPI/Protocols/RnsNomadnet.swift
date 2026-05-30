//
//  RnsNomadnet.swift
//  RNSAPI
//
//  NomadNet node-browsing facet — iOS analog of Android Columba's
//  `rns-api/RnsNomadnet`. Split out of RnsCore so the seam mirrors Android's
//  composed-interface shape.
//

import Foundation

public protocol RnsNomadnet: AnyObject, Sendable {

    /// One-shot NomadNet page fetch over a fresh RNS Link. `formFields`, when
    /// present, are submitted as the request's MessagePack map (caller prefixes
    /// `field_` per NomadNet's node-app convention).
    func fetchNomadNetPage(
        destHashHex: String,
        path: String,
        timeout: TimeInterval,
        formFields: [String: String]?
    ) async throws -> NomadNetFetchResult
}

public extension RnsNomadnet {
    func fetchNomadNetPage(destHashHex: String, path: String) async throws -> NomadNetFetchResult {
        try await fetchNomadNetPage(destHashHex: destHashHex, path: path, timeout: 30.0, formFields: nil)
    }
}
