import Foundation
import ImageIO
import UniformTypeIdentifiers
import Combine

/// A byte-preserving temporary file prepared for native attachment preview and export.
/// Each item owns one isolated UUID directory and removes only that directory.
final class MessageAttachmentPreviewItem: Identifiable {
    let id = UUID()
    let directoryURL: URL
    let url: URL

    private let fileManager: FileManager
    private let cleanupLock = NSLock()
    private var hasCleanedUp = false

    init(
        data: Data,
        suggestedFilename: String,
        declaredImageFormat: String? = nil,
        isImage: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directoryURL = directoryURL

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            let filename = Self.safeFilename(
                suggestedFilename,
                imageData: isImage ? data : nil,
                declaredImageFormat: declaredImageFormat
            )
            let url = directoryURL.appendingPathComponent(filename, isDirectory: false)
            try data.write(to: url, options: .atomic)
            self.url = url
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        cleanupLock.lock()
        guard !hasCleanedUp else {
            cleanupLock.unlock()
            return
        }
        hasCleanedUp = true
        cleanupLock.unlock()
        try? fileManager.removeItem(at: directoryURL)
    }

    private static func safeFilename(
        _ untrustedName: String,
        imageData: Data?,
        declaredImageFormat: String?
    ) -> String {
        let finalComponent = untrustedName
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let filtered = finalComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7f
        }
        var candidate = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate == "." || candidate == ".." {
            candidate = ""
        }

        let originalExtension = sanitizedExtension((candidate as NSString).pathExtension)
        var stem = (candidate as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if stem.isEmpty { stem = "attachment" }

        let imageExtension: String? = {
            if let imageData,
               let source = CGImageSourceCreateWithData(imageData as CFData, nil),
               let identifier = CGImageSourceGetType(source),
               let detectedType = UTType(identifier as String),
               let detected = detectedType.preferredFilenameExtension {
                return sanitizedExtension(detected)
            }
            guard let declaredImageFormat else { return nil }
            let declared = declaredImageFormat
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                .lowercased()
            let type = UTType(mimeType: declared) ?? UTType(filenameExtension: declared)
            guard let type, type.conforms(to: .image) else {
                return nil
            }
            return sanitizedExtension(type.preferredFilenameExtension ?? declared)
        }()

        let fileExtension = imageExtension ?? originalExtension
        let suffix = fileExtension.map { ".\($0)" } ?? ""
        let byteLimit = max(1, 120 - suffix.utf8.count)
        while stem.utf8.count > byteLimit, !stem.isEmpty {
            stem.removeLast()
        }
        if stem.isEmpty { stem = "attachment" }
        return stem + suffix
    }

    private static func sanitizedExtension(_ value: String) -> String? {
        let filtered = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !filtered.isEmpty, filtered.utf8.count <= 16 else { return nil }
        return filtered
    }
}

/// Owns the current preview item and synchronously cleans up the outgoing item
/// whenever SwiftUI replaces or dismisses the full-screen presentation.
@MainActor
final class MessageAttachmentPreviewStore: ObservableObject {
    @Published var item: MessageAttachmentPreviewItem? {
        willSet {
            guard item?.id != newValue?.id else { return }
            item?.cleanup()
        }
    }

    init(item: MessageAttachmentPreviewItem? = nil) {
        self.item = item
    }

    func present(_ item: MessageAttachmentPreviewItem) {
        self.item = item
    }

    func dismiss() {
        item = nil
    }

    func exitConversation() {
        item = nil
    }
}
