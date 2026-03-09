//
//  PlatformCompat.swift
//  ColumbaApp
//
//  Provides cross-platform compatibility shims for iOS-only SwiftUI modifiers.
//  On macOS, these become no-ops so the same view code compiles on both platforms.
//

import SwiftUI

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

#if os(iOS)
typealias PlatformImage = UIImage
#else
import AppKit
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

// MARK: - SharingDuration shim

/// Stub for LocationSharingManager's SharingDuration enum (iOS-only).
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
#endif
