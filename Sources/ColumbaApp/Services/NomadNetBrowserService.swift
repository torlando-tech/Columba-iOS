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
    /// Insertion-order list of destination hashes in the cache.
    /// Used to evict the oldest link when the cache is full — Swift
    /// dictionaries don't guarantee key ordering, so we track it explicitly.
    private var linkCacheOrder: [Data] = []
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
        logger.info("[NOMAD] Response \(responseData.count) bytes, first 32: \(responseData.prefix(32).hexString, privacy: .public)")

        guard let markup = String(data: responseData, encoding: .utf8) else {
            // Fallback: try Latin-1 (some NomadNet pages use non-UTF-8 encodings)
            if let markup = String(data: responseData, encoding: .isoLatin1) {
                let document = MicronParser.parse(markup)
                statusMessage = ""
                return (document, markup)
            }
            throw NomadNetError.invalidResponse("Response is not valid UTF-8 (\(responseData.count) bytes)")
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

        guard let markup = String(data: responseData, encoding: .utf8) ?? String(data: responseData, encoding: .isoLatin1) else {
            throw NomadNetError.invalidResponse("Response is not valid UTF-8 (\(responseData.count) bytes)")
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
        linkCacheOrder.removeAll { $0 == destinationHash }
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
            linkCacheOrder.removeAll { $0 == destinationHash }
            linkCache.removeValue(forKey: destinationHash)
        }

        // Resolve a VALID path (with a live interface). Returns nil if no path
        // arrives within the timeout or no live interface is available.
        guard let pathEntry = try await resolveValidPath(destinationHash: destinationHash) else {
            throw NomadNetError.noPath(destinationHash: destinationHash)
        }

        return try await establishLink(pathEntry: pathEntry, destinationHash: destinationHash)
    }

    /// Look up a path entry whose interface is currently registered. If the
    /// cached path points to a dead interface (e.g. leftover from a previous
    /// app run), invalidate it and wait for a fresh path.
    private func resolveValidPath(destinationHash: Data) async throws -> PathEntry? {
        let liveInterfaceIds = Set(await transport.listInterfaceIds())

        // First pass: is the current path valid?
        if let entry = await pathTable.lookup(destinationHash: destinationHash),
           liveInterfaceIds.contains(entry.interfaceId) {
            return entry
        }

        // Path is missing or stale. Invalidate and request a fresh one.
        statusMessage = "Resolving path..."
        await pathTable.remove(destinationHash: destinationHash)
        await transport.requestPath(for: destinationHash)

        // Poll up to 10 seconds for a new path to arrive on a live interface.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            let liveNow = Set(await transport.listInterfaceIds())
            if let entry = await pathTable.lookup(destinationHash: destinationHash),
               liveNow.contains(entry.interfaceId) {
                return entry
            }
        }

        return nil
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

        // Wait for link to become active, with a hard 20s timeout.
        // Race the state stream against a timeout task so we never hang if
        // the link silently stops producing state updates.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await linkState in await link.stateUpdates {
                    if linkState.isEstablished { return }
                    if case .closed = linkState {
                        throw NomadNetError.linkFailed("Link closed during establishment")
                    }
                }
                throw NomadNetError.linkFailed("State stream ended before link became active")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw NomadNetError.linkFailed("Link establishment timed out")
            }
            // Wait for whichever task finishes first, then cancel the rest.
            try await group.next()
            group.cancelAll()
        }

        // Evict oldest (FIFO) if at capacity — dictionaries have no stable
        // ordering, so we evict based on linkCacheOrder insertion order.
        if linkCache.count >= Self.maxCachedLinks, let oldestKey = linkCacheOrder.first {
            linkCacheOrder.removeFirst()
            if let old = linkCache.removeValue(forKey: oldestKey) {
                await old.close()
            }
        }

        linkCache[destinationHash] = link
        linkCacheOrder.append(destinationHash)
        return link
    }

    // MARK: - Response Handling

    private func waitForResponse(receipt: RequestReceipt) async throws -> Data {
        for await status in await receipt.statusUpdates {
            switch status {
            case .responseReceived:
                if let data = await receipt.responseData {
                    return unwrapResponseData(data)
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

    /// Unwrap MessagePack-encoded response data if needed.
    ///
    /// Reticulum wraps response payloads in MessagePack. For resource-based
    /// responses, the response data arrives as a MessagePack-packed value
    /// (e.g. `.binary(pageBytes)` or `.string(pageText)`). Extract the raw
    /// payload for the application layer.
    private func unwrapResponseData(_ data: Data) -> Data {
        // Try to unpack as MessagePack and extract the inner value
        if let value = try? unpackMsgPack(data) {
            switch value {
            case .binary(let bytes):
                return bytes
            case .string(let str):
                return str.data(using: .utf8) ?? data
            default:
                break
            }
        }
        return data
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
