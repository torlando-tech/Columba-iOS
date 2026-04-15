import Foundation
import SwiftUI
import ReticulumSwift

/// Navigation history entry for the NomadNet browser.
public struct NomadNetNavigationEntry: Sendable {
    public let nodeHash: Data
    public let path: String
    public let document: MicronDocument?
}

/// ViewModel for the NomadNet node page browser.
@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
public final class NomadNetBrowserViewModel {

    // MARK: - State

    public var currentDocument: MicronDocument?
    public var currentPath: String = "/page/index.mu"
    public var currentNodeHash: Data
    public var currentNodeName: String?
    public var isLoading: Bool = false
    public var statusMessage: String = ""
    public var errorMessage: String?

    // MARK: - Navigation

    private var navigationHistory: [NomadNetNavigationEntry] = []
    private static let maxHistorySize = 50

    public var canGoBack: Bool { !navigationHistory.isEmpty }

    /// URL display string: "hashPrefix:/path"
    public var displayURL: String {
        let hashHex = currentNodeHash.map { String(format: "%02x", $0) }.joined()
        return "\(hashHex):\(currentPath)"
    }

    // MARK: - Dependencies

    private let browserService: NomadNetBrowserService

    // MARK: - Init

    public init(
        nodeHash: Data,
        nodeName: String?,
        transport: ReticulumTransport,
        pathTable: PathTable,
        identity: Identity
    ) {
        self.currentNodeHash = nodeHash
        self.currentNodeName = nodeName
        self.browserService = NomadNetBrowserService(
            transport: transport,
            pathTable: pathTable,
            identity: identity
        )
    }

    // MARK: - Page Loading

    /// Load the current page.
    public func loadPage() async {
        isLoading = true
        errorMessage = nil

        do {
            let (document, _) = try await browserService.fetchPage(
                destinationHash: currentNodeHash,
                path: currentPath
            )
            currentDocument = document
            statusMessage = await browserService.statusMessage
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        statusMessage = ""
    }

    /// Navigate to a URL from a micron link.
    public func navigateTo(url: MicronURL) async {
        switch url {
        case .samePage(let path):
            pushHistory()
            currentPath = path
            await loadPage()

        case .remoteNode(let hash, let path):
            pushHistory()
            if let hashData = Data(hexString: hash) {
                currentNodeHash = hashData
                currentNodeName = nil
            }
            currentPath = path
            await loadPage()

        case .lxmf:
            // LXMF links are handled by the view layer (navigate to chat)
            break
        }
    }

    /// Go back in navigation history.
    public func goBack() async {
        guard let previous = navigationHistory.popLast() else { return }

        currentNodeHash = previous.nodeHash
        currentPath = previous.path

        if let doc = previous.document {
            currentDocument = doc
        } else {
            await loadPage()
        }
    }

    /// Refresh the current page (bypasses cache).
    public func refresh() async {
        await browserService.clearCache()
        await loadPage()
    }

    /// Reveal identity to the current node.
    public func identifyToNode() async {
        do {
            try await browserService.identifyToNode(destinationHash: currentNodeHash)
            // Refresh page after identifying (node may show different content)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Handle a link tap from the micron document.
    public func handleLinkTap(_ link: MicronLink) async {
        await navigateTo(url: link.url)
    }

    // MARK: - History

    private func pushHistory() {
        let entry = NomadNetNavigationEntry(
            nodeHash: currentNodeHash,
            path: currentPath,
            document: currentDocument
        )
        navigationHistory.append(entry)
        if navigationHistory.count > Self.maxHistorySize {
            navigationHistory.removeFirst()
        }
    }

    /// Start polling status from the service during loading.
    public func pollStatus() async {
        while isLoading {
            statusMessage = await browserService.statusMessage
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

