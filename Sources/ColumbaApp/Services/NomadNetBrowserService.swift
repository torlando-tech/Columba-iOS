#if COLUMBA_NOMADNET_ENABLED
import Foundation
import RNSAPI
import os.log

private let logger = Logger(subsystem: "network.columba.Columba", category: "NomadNetBrowser")

/// One-shot page fetching for NomadNet node browsing.
///
/// Earlier versions of this service managed RNS Link / RequestReceipt
/// lifecycles directly. Now it delegates the whole link-establishment +
/// request + teardown dance to `PythonRNSBackend.fetchNomadNetPage`,
/// which runs the canonical Mark Qvist RNS code under the embedded
/// CPython. Trades a few hundred ms of link re-establishment per fetch
/// for a much smaller API surface and zero protocol re-implementation
/// in Swift.
///
/// The page cache (12h default, overridable by `cache_seconds` page
/// header) stays here on the Swift side — there's no point round-tripping
/// to Python for a cache hit.
public actor NomadNetBrowserService {

    // MARK: - Dependencies

    private let backend: PythonRNSBackend
    private let localIdentity: Identity

    // MARK: - Page Cache

    private struct CachedPage {
        let document: MicronDocument
        let rawMarkup: String
        let fetchedAt: Date
        let cacheSeconds: Int
    }
    private var pageCache: [String: CachedPage] = [:]
    private static let defaultCacheSeconds = 43200 // 12 hours

    // MARK: - Status

    public private(set) var statusMessage: String = ""

    // MARK: - Init

    public init(backend: PythonRNSBackend, identity: Identity) {
        self.backend = backend
        self.localIdentity = identity
    }

    // MARK: - Page Fetching

    /// Fetch a page from a NomadNet node.
    /// Returns the parsed document and raw markup.
    public func fetchPage(
        destinationHash: Data,
        path: String = "/page/index.mu"
    ) async throws -> (MicronDocument, String) {
        let destHashHex = destinationHash.toHex()
        let cacheKey = "\(destHashHex):\(path)"

        // Check page cache
        if let cached = pageCache[cacheKey] {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            if cached.cacheSeconds > 0 && age < Double(cached.cacheSeconds) {
                logger.info("[NOMAD] Cache hit for \(cacheKey, privacy: .public)")
                return (cached.document, cached.rawMarkup)
            } else {
                pageCache.removeValue(forKey: cacheKey)
            }
        }

        statusMessage = "Fetching \(path)..."
        logger.info("[NOMAD] Fetching \(path, privacy: .public) from \(destHashHex.prefix(8), privacy: .public)")

        let result = try await backend.fetchNomadNetPage(
            destHashHex: destHashHex,
            path: path,
            timeout: 30.0,
            formFields: nil
        )

        try ensureSuccess(result)

        let responseData = result.data
        logger.info("[NOMAD] Response \(responseData.count) bytes")

        guard let markup = decodeMarkup(responseData) else {
            throw NomadNetError.invalidResponse("Response is not valid UTF-8 / Latin-1 (\(responseData.count) bytes)")
        }
        let document = MicronParser.parse(markup)

        let cacheSeconds = document.headers.cacheSeconds ?? Self.defaultCacheSeconds
        if cacheSeconds > 0 {
            pageCache[cacheKey] = CachedPage(
                document: document,
                rawMarkup: markup,
                fetchedAt: Date(),
                cacheSeconds: cacheSeconds
            )
        }

        statusMessage = ""
        return (document, markup)
    }

    /// Submit form data to a NomadNet node page.
    public func submitForm(
        destinationHash: Data,
        path: String,
        fields: [String: String]
    ) async throws -> (MicronDocument, String) {
        statusMessage = "Submitting form..."

        // NomadNet's node app expects form fields keyed with a "field_"
        // prefix. The Python bridge msgpack-packs the dict on its side.
        var prefixed: [String: String] = [:]
        for (k, v) in fields { prefixed["field_\(k)"] = v }

        let result = try await backend.fetchNomadNetPage(
            destHashHex: destinationHash.toHex(),
            path: path,
            timeout: 30.0,
            formFields: prefixed
        )
        try ensureSuccess(result)

        let responseData = result.data
        guard let markup = decodeMarkup(responseData) else {
            throw NomadNetError.invalidResponse("Form response is not text (\(responseData.count) bytes)")
        }
        let document = MicronParser.parse(markup)
        statusMessage = ""
        return (document, markup)
    }

    /// Download a file from a NomadNet node.
    /// Returns the file data and suggested filename.
    public func downloadFile(
        destinationHash: Data,
        path: String
    ) async throws -> (Data, String) {
        statusMessage = "Downloading file..."
        logger.info("[NOMAD] Downloading \(path, privacy: .public)")

        let result = try await backend.fetchNomadNetPage(
            destHashHex: destinationHash.toHex(),
            path: path,
            timeout: 60.0,
            formFields: nil
        )
        try ensureSuccess(result)

        let filename = path.split(separator: "/").last.map(String.init) ?? "download"
        statusMessage = ""
        return (result.data, filename)
    }

    /// Compatibility no-op. We now establish a fresh Link for each fetch,
    /// so there's nothing to identify against on a long-lived link.
    /// Stateful node apps that require the identity round-trip will need
    /// the underlying Python bridge to thread identity through each
    /// request (rns_bridge.fetch_nomadnet_page already does
    /// `link.identify(_state["identity"])`).
    public func identifyToNode(destinationHash: Data) async throws {
        logger.info("[NOMAD] identifyToNode is a no-op under PythonRNSBackend (auto-identified per request)")
    }

    /// Compatibility no-op. No cached links to close — each fetch
    /// tears down its own Link in Python.
    public func closeLink(destinationHash: Data) async {}

    /// Clear all caches.
    public func clearCache() {
        pageCache.removeAll()
    }

    // MARK: - Helpers

    private func ensureSuccess(_ result: PythonBridge.NomadNetFetchResult) throws {
        if result.ok { return }
        switch result.status {
        case .noPath: throw NomadNetError.noPath(destinationHash: Data())
        case .linkFailed: throw NomadNetError.linkFailed("Link establishment timed out or failed")
        case .timeout: throw NomadNetError.timeout
        case .badHash, .notStarted, .requestFailed, .unknown:
            throw NomadNetError.requestFailed("\(result.status.rawValue) \(result.contentType)")
        case .ok: return
        }
    }

    private func decodeMarkup(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1)
    }
}

public enum NomadNetError: Error, LocalizedError {
    case noPath(destinationHash: Data)
    case linkFailed(String)
    case timeout
    case invalidResponse(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noPath(let hash):
            return "No path to node \(hash.prefix(4).toHex()) — try again in a few seconds"
        case .linkFailed(let reason):
            return "Could not connect: \(reason)"
        case .timeout:
            return "Request timed out"
        case .invalidResponse(let reason):
            return "Bad response: \(reason)"
        case .requestFailed(let reason):
            return "Request failed: \(reason)"
        }
    }
}
#endif
