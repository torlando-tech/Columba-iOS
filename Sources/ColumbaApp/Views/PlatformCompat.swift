//
//  PlatformCompat.swift
//  ColumbaApp
//
//  Provides cross-platform compatibility shims for iOS-only SwiftUI modifiers.
//  On macOS, these become no-ops so the same view code compiles on both platforms.
//

import SwiftUI
import RNSAPI
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

// `PeerLocation`, `PropagationTransferState`, and `SharingDuration` are
// canonicalized in RNSAPI/Compat.swift (same fields/cases as before — fields
// were copied in verbatim). Duplicating them here caused
// "is ambiguous for type lookup" errors in the Xcode build, since RNSAPI is
// now also a compile-time dependency of the ColumbaApp target.
