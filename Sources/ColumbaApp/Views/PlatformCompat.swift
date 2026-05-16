//
//  PlatformCompat.swift
//  ColumbaApp
//
//  Provides cross-platform compatibility shims for iOS-only SwiftUI modifiers.
//  On macOS, these become no-ops so the same view code compiles on both platforms.
//

import SwiftUI
#if !os(iOS)
import AppKit
#endif

// MARK: - Cross-platform Image helper

extension Image {
    /// Create an Image from a platform image type (UIImage on iOS, NSImage on macOS).
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

// MARK: - Cross-platform system colors

extension Color {
    static var platformSystemBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    static var platformSystemGray6: Color {
        #if os(iOS)
        Color(.systemGray6)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage

// MARK: - NavigationBarItem shim

/// Shim for iOS NavigationBarItem.TitleDisplayMode so existing code compiles on macOS.
enum NavigationBarItem {
    enum TitleDisplayMode {
        case automatic, inline, large
    }
}

extension View {
    /// No-op on macOS — iOS uses this for large/inline title styles.
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }
}

// MARK: - UIImage shim

/// Typealias so code referencing UIImage compiles on macOS.
typealias UIImage = NSImage

extension NSImage {
    /// Compatibility shim: return PNG data (matches UIImage.pngData()).
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Compatibility shim: return JPEG data (matches UIImage.jpegData(compressionQuality:)).
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

#endif

// MARK: - PeerLocation shim (cross-platform)

/// Stub for LocationSharingManager's PeerLocation. Mirrors the real shape so
/// MapLibreMapView compiles when COLUMBA_LOCATION_ENABLED is off.
public struct PeerLocation: Identifiable, Equatable {
    public let id: Data
    public var displayName: String?
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var speed: Double
    public var bearing: Double
    public var accuracy: Double
    public var lastUpdate: Date
    public var iconAppearance: IconAppearance?

    public init(
        id: Data,
        displayName: String? = nil,
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        speed: Double = 0,
        bearing: Double = 0,
        accuracy: Double = 0,
        lastUpdate: Date = Date(),
        iconAppearance: IconAppearance? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.bearing = bearing
        self.accuracy = accuracy
        self.lastUpdate = lastUpdate
        self.iconAppearance = iconAppearance
    }

    public var isStale: Bool { Date().timeIntervalSince(lastUpdate) > 300 }
    public var shortHash: String { id.prefix(4).map { String(format: "%02x", $0) }.joined() }
}

// MARK: - PropagationTransferState shim (cross-platform)

/// Stub for the propagation sync state observed by PropagationNodeManager.
public struct PropagationTransferState: Equatable {
    public enum State: Equatable {
        case idle
        case linking
        case linked
        case linkFailed
        case transferring
        case transferFailed
        case noPath
        case complete
    }
    public var state: State
    public var receivedMessages: Int
    public var errorDescription: String?
    public var lastSync: Date?
    public var progress: Double

    public init(
        state: State = .idle,
        receivedMessages: Int = 0,
        errorDescription: String? = nil,
        lastSync: Date? = nil,
        progress: Double = 0
    ) {
        self.state = state
        self.receivedMessages = receivedMessages
        self.errorDescription = errorDescription
        self.lastSync = lastSync
        self.progress = progress
    }

    public var isSyncing: Bool {
        switch state {
        case .linking, .linked, .transferring: return true
        default: return false
        }
    }
}

// MARK: - SharingDuration shim (cross-platform)

/// Stub for LocationSharingManager's SharingDuration enum. Lifted out of the
/// macOS `#else` branch so iOS sees it too when COLUMBA_LOCATION_ENABLED is off.
public enum SharingDuration: String, CaseIterable, Identifiable {
    case fifteenMinutes = "15 min"
    case oneHour = "1 hour"
    case fourHours = "4 hours"
    case untilMidnight = "Until midnight"
    case indefinite = "Until I stop"

    public var id: String { rawValue }

    public func calculateEndDate(from start: Date = Date()) -> Date? {
        switch self {
        case .fifteenMinutes: return start.addingTimeInterval(15 * 60)
        case .oneHour: return start.addingTimeInterval(60 * 60)
        case .fourHours: return start.addingTimeInterval(4 * 60 * 60)
        case .untilMidnight:
            var cal = Calendar.current
            cal.timeZone = .current
            return cal.nextDate(after: start, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        case .indefinite: return nil
        }
    }
}
