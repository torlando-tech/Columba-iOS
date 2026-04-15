import Foundation
import ReticulumSwift
import os.log

private let logger = Logger(subsystem: "com.columba.app", category: "NomadNetBrowser")

/// Manages Link establishment and page fetching for NomadNet node browsing.
public actor NomadNetBrowserService {

    // MARK: - Dependencies

    private let transport: ReticulumTransport
    private let pathTable: PathTable
    private let localIdentity: Identity

    // MARK: - Link Cache

    private var linkCache: [Data: Link] = [:]
    private static let maxCachedLinks = 8

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

    public init(transport: ReticulumTransport, pathTable: PathTable, identity: Identity) {
        self.transport = transport
        self.pathTable = pathTable
        self.localIdentity = identity
    }

    // MARK: - Page Fetching

    /// Fetch a page from a NomadNet node.
    /// Returns the parsed document and raw markup.
    public func fetchPage(
        destinationHash: Data,
        path: String = "/page/index.mu"
    ) async throws -> (MicronDocument, String) {
        let cacheKey = "\(destinationHash.hexString):\(path)"

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

        // Establish or reuse link
        statusMessage = "Establishing link..."
        let link = try await getOrCreateLink(destinationHash: destinationHash)

        // Request page
        statusMessage = "Requesting page..."
        logger.info("[NOMAD] Requesting \(path, privacy: .public) from \(destinationHash.prefix(4).hexString, privacy: .public)")

        let receipt = try await link.request(path: path, data: nil, timeout: 30.0)

        // Wait for response
        statusMessage = "Loading response..."
        let responseData = try await waitForResponse(receipt: receipt)

        guard let markup = String(data: responseData, encoding: .utf8) else {
            throw NomadNetError.invalidResponse("Response is not valid UTF-8")
        }

        let document = MicronParser.parse(markup)

        // Cache the page
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
        let link = try await getOrCreateLink(destinationHash: destinationHash)

        statusMessage = "Submitting form..."

        // Build field data with "field_" prefix per NomadNet protocol
        var fieldMap: [MessagePackValue: MessagePackValue] = [:]
        for (key, value) in fields {
            fieldMap[.string("field_\(key)")] = .string(value)
        }

        let receipt = try await link.request(
            path: path,
            data: .map(fieldMap),
            timeout: 30.0
        )

        let responseData = try await waitForResponse(receipt: receipt)

        guard let markup = String(data: responseData, encoding: .utf8) else {
            throw NomadNetError.invalidResponse("Response is not valid UTF-8")
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
        let link = try await getOrCreateLink(destinationHash: destinationHash)

        statusMessage = "Downloading file..."
        logger.info("[NOMAD] Downloading \(path, privacy: .public)")

        let receipt = try await link.request(path: path, data: nil, timeout: 60.0)
        let data = try await waitForResponse(receipt: receipt)

        // Extract filename from path
        let filename = path.split(separator: "/").last.map(String.init) ?? "download"
        statusMessage = ""
        return (data, filename)
    }

    /// Reveal local identity to the node.
    public func identifyToNode(destinationHash: Data) async throws {
        let link = try await getOrCreateLink(destinationHash: destinationHash)
        statusMessage = "Identifying..."
        try await link.identify(identity: localIdentity)
        statusMessage = ""
        logger.info("[NOMAD] Identified to node \(destinationHash.prefix(4).hexString, privacy: .public)")
    }

    /// Close a cached link to a node.
    public func closeLink(destinationHash: Data) async {
        if let link = linkCache.removeValue(forKey: destinationHash) {
            await link.close()
        }
    }

    /// Clear all caches.
    public func clearCache() {
        pageCache.removeAll()
    }

    // MARK: - Link Management

    private func getOrCreateLink(destinationHash: Data) async throws -> Link {
        // Check cache for active link
        if let cached = linkCache[destinationHash] {
            let linkState = await cached.state
            if linkState.isEstablished {
                return cached
            }
            linkCache.removeValue(forKey: destinationHash)
        }

        // Look up path entry to get remote public keys
        guard let pathEntry = await pathTable.lookup(destinationHash: destinationHash) else {
            // Try requesting path
            statusMessage = "Resolving path..."
            await transport.requestPath(for: destinationHash)

            // Poll for path (up to 10 seconds)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(500))
                if await pathTable.hasPath(for: destinationHash) {
                    break
                }
            }

            guard let entry = await pathTable.lookup(destinationHash: destinationHash) else {
                throw NomadNetError.noPath(destinationHash: destinationHash)
            }
            return try await establishLink(pathEntry: entry, destinationHash: destinationHash)
        }

        return try await establishLink(pathEntry: pathEntry, destinationHash: destinationHash)
    }

    private func establishLink(pathEntry: PathEntry, destinationHash: Data) async throws -> Link {
        statusMessage = "Establishing link..."

        let remoteIdentity = try Identity(publicKeyBytes: pathEntry.publicKeys)
        let destination = Destination(
            identity: remoteIdentity,
            appName: "nomadnetwork",
            aspects: ["node"],
            direction: .out
        )

        let link = try await transport.initiateLink(to: destination, identity: localIdentity)

        // Wait for link to become active (up to 15 seconds)
        let deadline = Date().addingTimeInterval(15.0)
        for await linkState in await link.stateUpdates {
            if linkState.isEstablished {
                break
            }
            if case .closed = linkState {
                throw NomadNetError.linkFailed("Link closed during establishment")
            }
            if Date() > deadline {
                throw NomadNetError.linkFailed("Link establishment timed out")
            }
        }

        // Evict oldest if at capacity
        if linkCache.count >= Self.maxCachedLinks {
            if let oldestKey = linkCache.keys.first {
                if let old = linkCache.removeValue(forKey: oldestKey) {
                    await old.close()
                }
            }
        }

        linkCache[destinationHash] = link
        return link
    }

    // MARK: - Response Handling

    private func waitForResponse(receipt: RequestReceipt) async throws -> Data {
        for await status in await receipt.statusUpdates {
            switch status {
            case .responseReceived:
                if let data = await receipt.responseData {
                    return data
                }
                throw NomadNetError.invalidResponse("Response received but no data")
            case .failed(let reason):
                throw NomadNetError.requestFailed(reason)
            case .timeout:
                throw NomadNetError.timeout
            default:
                continue
            }
        }
        throw NomadNetError.requestFailed("Status stream ended without response")
    }
}

// MARK: - Errors

public enum NomadNetError: Error, LocalizedError {
    case noPath(destinationHash: Data)
    case linkFailed(String)
    case requestFailed(String)
    case invalidResponse(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .noPath(let hash):
            return "No path to node \(hash.prefix(4).hexString)"
        case .linkFailed(let msg):
            return "Link failed: \(msg)"
        case .requestFailed(let msg):
            return "Request failed: \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .timeout:
            return "Request timed out"
        }
    }
}

// MARK: - Data Hex Helper

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
