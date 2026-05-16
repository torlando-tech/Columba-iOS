#if COLUMBA_NOMADNET_ENABLED
import Foundation
import RNSAPI
import SwiftUI

/// Rendering mode for NomadNet pages.
public enum NomadNetRenderingMode: String, Sendable, CaseIterable {
    /// Monospace font with horizontal+vertical scroll, square line height, pinch zoom.
    /// Best for ASCII art and pixel art pages.
    case monospaceScroll
    /// Compact monospace with vertical scroll and text wrapping.
    /// Best for dense text content.
    case monospaceZoom
    /// System (proportional) font with vertical scroll and text wrapping.
    /// Best for readable prose.
    case proportionalWrap

    public var displayName: String {
        switch self {
        case .monospaceScroll: return "Monospace (scroll)"
        case .monospaceZoom: return "Monospace (zoom)"
        case .proportionalWrap: return "Proportional (wrap)"
        }
    }

    public var iconName: String {
        switch self {
        case .monospaceScroll: return "arrow.up.and.down.and.arrow.left.and.right"
        case .monospaceZoom: return "textformat.size.smaller"
        case .proportionalWrap: return "text.alignleft"
        }
    }
}

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
    public var downloadedFileURL: URL?
    public var downloadedFileName: String?
    public var showingShareSheet: Bool = false

    /// Current rendering mode (persisted to UserDefaults).
    public var renderingMode: NomadNetRenderingMode = {
        if let raw = UserDefaults.standard.string(forKey: "nomadnet.renderingMode"),
           let mode = NomadNetRenderingMode(rawValue: raw) {
            return mode
        }
        return .monospaceScroll
    }() {
        didSet {
            UserDefaults.standard.set(renderingMode.rawValue, forKey: "nomadnet.renderingMode")
        }
    }

    /// Loaded partial content keyed by partial URL or partial ID.
    public var partialDocuments: [String: MicronDocument] = [:]
    /// Partials currently loading.
    public var loadingPartials: Set<String> = []
    /// Outstanding auto-refresh tasks keyed by partial id/url. Cancelled on page change
    /// so N navigations cannot accumulate N parallel refresh chains.
    private var partialRefreshTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Form State

    /// Text/password field values keyed by field name.
    public var formFields: [String: String] = [:]
    /// Checkbox states keyed by "name:value".
    public var checkboxFields: [String: Bool] = [:]
    /// Radio button selections keyed by group name.
    public var radioFields: [String: String] = [:]

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
        backend: PythonRNSBackend,
        identity: Identity
    ) {
        self.currentNodeHash = nodeHash
        self.currentNodeName = nodeName
        self.browserService = NomadNetBrowserService(
            backend: backend,
            identity: identity
        )
    }

    // MARK: - Page Loading

    /// Load the current page.
    public func loadPage() async {
        cancelPartialRefreshTasks()
        isLoading = true
        errorMessage = nil

        do {
            let (document, _) = try await browserService.fetchPage(
                destinationHash: currentNodeHash,
                path: currentPath
            )
            currentDocument = document
            partialDocuments.removeAll()
            initializeFormDefaults(from: document)
            statusMessage = await browserService.statusMessage
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        statusMessage = ""

        // Load partials after main page
        await loadPartials()
    }

    /// Navigate to a URL from a micron link.
    public func navigateTo(url: MicronURL) async {
        switch url {
        case .samePage(let path):
            if path.hasPrefix("/file/") {
                await downloadFile(nodeHash: currentNodeHash, path: path)
                return
            }
            pushHistory()
            currentPath = path
            await loadPage()

        case .remoteNode(let hash, let path):
            // Decode hash first — bail with an error if it's malformed rather
            // than silently fetching the new path from the previous node.
            guard let hashData = Data(hexString: hash) else {
                errorMessage = "Invalid node hash in link: \(hash)"
                return
            }
            if path.hasPrefix("/file/") {
                await downloadFile(nodeHash: hashData, path: path)
                return
            }
            pushHistory()
            currentNodeHash = hashData
            currentNodeName = nil
            currentPath = path
            await loadPage()

        case .lxmf:
            // LXMF links are handled by the view layer (navigate to chat)
            break
        }
    }

    /// Download a file from a node.
    public func downloadFile(nodeHash: Data, path: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let (data, filename) = try await browserService.downloadFile(
                destinationHash: nodeHash,
                path: path
            )
            // Save to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(filename)
            try data.write(to: fileURL)
            downloadedFileURL = fileURL
            downloadedFileName = filename
            showingShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        statusMessage = ""
    }

    /// Go back in navigation history.
    public func goBack() async {
        guard let previous = navigationHistory.popLast() else { return }

        cancelPartialRefreshTasks()
        currentNodeHash = previous.nodeHash
        currentPath = previous.path

        if let doc = previous.document {
            currentDocument = doc
            // Reseed form state from the restored page so fields don't show
            // the forward-page's values after a back navigation.
            initializeFormDefaults(from: doc)
            await loadPartials()
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
        if let fieldNames = link.fieldNames, !fieldNames.isEmpty {
            // Form submission link — collect field values and submit
            await submitForm(url: link.url, fieldNames: fieldNames)
        } else {
            await navigateTo(url: link.url)
        }
    }

    /// Submit form fields to a page.
    public func submitForm(url: MicronURL, fieldNames: [String]) async {
        let fields = collectFormFields(fieldNames: fieldNames)

        // Resolve target node hash and path from the URL. Reject LXMF targets
        // (no form submission semantics) and bail on invalid remote hashes
        // rather than silently submitting to the previous node.
        let targetHash: Data
        let targetPath: String
        switch url {
        case .samePage(let path):
            targetHash = currentNodeHash
            targetPath = path
        case .remoteNode(let hash, let path):
            guard let hashData = Data(hexString: hash) else {
                errorMessage = "Invalid node hash in form action: \(hash)"
                return
            }
            targetHash = hashData
            targetPath = path
        case .lxmf:
            return
        }

        cancelPartialRefreshTasks()
        pushHistory()
        if case .remoteNode = url {
            currentNodeHash = targetHash
            currentNodeName = nil
        }
        currentPath = targetPath
        isLoading = true
        errorMessage = nil

        do {
            let (document, _) = try await browserService.submitForm(
                destinationHash: targetHash,
                path: targetPath,
                fields: fields
            )
            currentDocument = document
            initializeFormDefaults(from: document)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        statusMessage = ""

        await loadPartials()
    }

    // MARK: - Partials

    /// Load all partials in the current document.
    public func loadPartials() async {
        guard let document = currentDocument else { return }
        for element in document.elements {
            guard case .partial(let partial) = element else { continue }
            await loadPartial(partial)
        }
    }

    /// Load a single partial.
    public func loadPartial(_ partial: MicronPartial) async {
        let key = partial.partialId ?? partial.url
        loadingPartials.insert(key)

        do {
            let (document, _) = try await browserService.fetchPage(
                destinationHash: currentNodeHash,
                path: partial.url
            )
            partialDocuments[key] = document
        } catch {
            // Partials fail silently — show empty content
        }

        loadingPartials.remove(key)

        // Set up auto-refresh if configured. Each partial has at most one
        // in-flight refresh task; scheduling a new one cancels the previous.
        // All outstanding tasks are cancelled in cancelPartialRefreshTasks()
        // when the page changes, so navigations cannot stack chains.
        if let interval = partial.refreshInterval, interval > 0 {
            partialRefreshTasks[key]?.cancel()
            partialRefreshTasks[key] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                guard let self else { return }
                guard self.currentDocument != nil else { return }
                await self.loadPartial(partial)
            }
        }
    }

    /// Cancel all in-flight partial auto-refresh tasks. Call before state
    /// transitions that invalidate the current page.
    private func cancelPartialRefreshTasks() {
        for task in partialRefreshTasks.values {
            task.cancel()
        }
        partialRefreshTasks.removeAll()
    }

    // MARK: - Form Helpers

    /// Initialize form field defaults from a document.
    private func initializeFormDefaults(from document: MicronDocument) {
        formFields.removeAll()
        checkboxFields.removeAll()
        radioFields.removeAll()

        for element in document.elements {
            guard case .formField(let field) = element else { continue }
            switch field {
            case .textInput(_, let name, let defaultValue):
                formFields[name] = defaultValue
            case .passwordInput(let name, let defaultValue):
                formFields[name] = defaultValue
            case .checkbox(let name, let value, _, let checked):
                checkboxFields["\(name):\(value)"] = checked
            case .radio(let name, let value, _, let selected):
                if selected {
                    radioFields[name] = value
                }
            }
        }
    }

    /// Collect form field values for submission.
    private func collectFormFields(fieldNames: [String]) -> [String: String] {
        var result: [String: String] = [:]
        let submitAll = fieldNames.contains("*")

        for (name, value) in formFields {
            if submitAll || fieldNames.contains(name) {
                result[name] = value
            }
        }

        // Collect checked checkboxes — concatenate values with same name
        var checkboxValues: [String: [String]] = [:]
        for (key, checked) in checkboxFields where checked {
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let value = String(parts[1])
            if submitAll || fieldNames.contains(name) {
                checkboxValues[name, default: []].append(value)
            }
        }
        for (name, values) in checkboxValues {
            result[name] = values.joined(separator: ",")
        }

        // Collect radio selections
        for (name, value) in radioFields {
            if submitAll || fieldNames.contains(name) {
                result[name] = value
            }
        }

        return result
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

#endif
