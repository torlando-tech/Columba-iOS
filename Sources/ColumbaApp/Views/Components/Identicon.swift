//
//  Identicon.swift
//  ColumbaApp
//
//  SwiftUI View that renders a unique visual identity from a hash.
//  Displays colored dots in a symmetric grid pattern on a circular background.
//
//  Compatible with ReticulumSwift Identity type.
//

import SwiftUI
import RNSAPI

/// A circular identicon view generated from a hash.
///
/// Creates a unique visual identity using colored dots arranged in a symmetric grid.
/// The pattern is deterministic - the same hash always produces the same identicon.
///
/// Example usage:
/// ```swift
/// // From 16-byte hash Data
/// Identicon(hash: identity.hash)
///     .frame(width: 48, height: 48)
///
/// // From hex string
/// Identicon(hexHash: "a1b2c3d4e5f6...")
///     .frame(width: 64, height: 64)
///
/// // With custom grid size
/// Identicon(hash: hash, gridSize: 6)
/// ```
@available(iOS 17.0, macOS 14.0, *)
public struct Identicon: View {
    // MARK: - Properties

    /// The generated pattern data.
    private let pattern: IdenticonGenerator.Pattern

    /// Size of individual dots relative to cell size.
    private let dotScale: CGFloat

    /// Spacing between dots relative to cell size.
    private let dotSpacing: CGFloat

    // MARK: - Initialization

    /// Create an identicon from raw hash data.
    ///
    /// - Parameters:
    ///   - hash: 16-byte identity hash
    ///   - gridSize: Number of rows/columns (default 5)
    ///   - dotScale: Size of dots relative to cell (default 0.7)
    ///   - dotSpacing: Spacing multiplier (default 1.0)
    public init(
        hash: Data,
        gridSize: Int = 5,
        dotScale: CGFloat = 0.7,
        dotSpacing: CGFloat = 1.0
    ) {
        self.pattern = IdenticonGenerator.cachedPattern(from: hash, gridSize: gridSize)
        self.dotScale = dotScale
        self.dotSpacing = dotSpacing
    }

    /// Create an identicon from a hex string hash.
    ///
    /// - Parameters:
    ///   - hexHash: Hex string representation of hash
    ///   - gridSize: Number of rows/columns (default 5)
    ///   - dotScale: Size of dots relative to cell (default 0.7)
    ///   - dotSpacing: Spacing multiplier (default 1.0)
    public init(
        hexHash: String,
        gridSize: Int = 5,
        dotScale: CGFloat = 0.7,
        dotSpacing: CGFloat = 1.0
    ) {
        self.pattern = IdenticonGenerator.cachedPattern(fromHex: hexHash, gridSize: gridSize)
        self.dotScale = dotScale
        self.dotSpacing = dotSpacing
    }

    /// Create an identicon from a pre-generated pattern.
    ///
    /// - Parameters:
    ///   - pattern: Pre-generated pattern
    ///   - dotScale: Size of dots relative to cell (default 0.7)
    ///   - dotSpacing: Spacing multiplier (default 1.0)
    public init(
        pattern: IdenticonGenerator.Pattern,
        dotScale: CGFloat = 0.7,
        dotSpacing: CGFloat = 1.0
    ) {
        self.pattern = pattern
        self.dotScale = dotScale
        self.dotSpacing = dotSpacing
    }

    // MARK: - Body

    public var body: some View {
        Canvas { context, canvasSize in
            let size = min(canvasSize.width, canvasSize.height)
            let padding = size * 0.15
            let gridArea = size - (padding * 2)
            let cellSize = gridArea / CGFloat(pattern.gridSize) * dotSpacing
            let dotRadius = cellSize * dotScale / 2
            let gridOffset = (size - gridArea) / 2

            // Background circle
            let bgPath = Path(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size))
            context.fill(bgPath, with: .color(pattern.backgroundColor))

            // Dot grid — single draw call per dot
            for row in 0..<pattern.gridSize {
                for col in 0..<pattern.gridSize {
                    if pattern.cells[row][col] {
                        let cx = gridOffset + cellSize * (CGFloat(col) + 0.5)
                        let cy = gridOffset + cellSize * (CGFloat(row) + 0.5)
                        let dotRect = CGRect(x: cx - dotRadius, y: cy - dotRadius,
                                             width: dotRadius * 2, height: dotRadius * 2)
                        let dotPath = Path(ellipseIn: dotRect)
                        context.fill(dotPath, with: .color(pattern.colors[row][col]))
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Convenience Extensions

@available(iOS 17.0, macOS 14.0, *)
extension Identicon {
    /// Create a placeholder identicon with a default pattern.
    ///
    /// Useful for loading states or when no identity is available.
    public static var placeholder: Identicon {
        Identicon(hash: Data(repeating: 0, count: 16))
    }

    /// Create a random identicon for testing/previews.
    public static var random: Identicon {
        Identicon(pattern: IdenticonGenerator.randomPattern())
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, macOS 14.0, *)
struct Identicon_Previews: PreviewProvider {
    /// Generate deterministic hash for preview index.
    private static func previewHash(for index: Int) -> Data {
        Data((0..<16).map { j in UInt8((index * 31 + j * 17) % 256) })
    }

    /// Sample hash for grid size comparison.
    private static let sampleHash = Data([
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
    ])

    static var previews: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Identicons")
                    .font(.title)
                    .foregroundStyle(.white)

                // Grid of different identicons
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    ForEach(0..<8, id: \.self) { i in
                        Identicon(hash: previewHash(for: i))
                            .frame(width: 64, height: 64)
                    }
                }

                Divider()
                    .background(Color.gray)

                // Size comparison
                Text("Size Comparison")
                    .font(.headline)
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    VStack {
                        Identicon(hash: previewHash(for: 100))
                            .frame(width: 32, height: 32)
                        Text("32pt")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    VStack {
                        Identicon(hash: previewHash(for: 101))
                            .frame(width: 48, height: 48)
                        Text("48pt")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    VStack {
                        Identicon(hash: previewHash(for: 102))
                            .frame(width: 64, height: 64)
                        Text("64pt")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    VStack {
                        Identicon(hash: previewHash(for: 103))
                            .frame(width: 96, height: 96)
                        Text("96pt")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }

                Divider()
                    .background(Color.gray)

                // Grid size comparison
                Text("Grid Size Comparison")
                    .font(.headline)
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    VStack {
                        Identicon(hash: sampleHash, gridSize: 4)
                            .frame(width: 64, height: 64)
                        Text("4x4")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    VStack {
                        Identicon(hash: sampleHash, gridSize: 5)
                            .frame(width: 64, height: 64)
                        Text("5x5")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    VStack {
                        Identicon(hash: sampleHash, gridSize: 6)
                            .frame(width: 64, height: 64)
                        Text("6x6")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
            }
            .padding()
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
