//
//  IdenticonGenerator.swift
//  ColumbaApp
//
//  Algorithm for generating unique visual identities from hash bytes.
//  Creates symmetric dot patterns with bright colors on dark backgrounds.
//
//  Compatible with ReticulumSwift Identity.hash (16-byte Data).
//

import SwiftUI
import RNSAPI

/// Generates identicon pattern data from a hash.
///
/// The algorithm:
/// 1. Uses hash bytes to determine which cells in a grid are filled
/// 2. Creates horizontal symmetry by mirroring the left half
/// 3. Maps hash bytes to colors from a curated palette
/// 4. Derives background color from remaining hash bytes
///
/// Example:
/// ```swift
/// let hash = identity.hash  // 16-byte Data
/// let pattern = IdenticonGenerator.generate(from: hash)
/// // Use pattern.cells, pattern.colors, pattern.backgroundColor
/// ```
public struct IdenticonGenerator {

    // MARK: - Types

    /// Generated identicon pattern data.
    public struct Pattern {
        /// Grid of filled cells (true = dot present).
        /// Outer array is rows, inner array is columns.
        public let cells: [[Bool]]

        /// Colors for each filled cell, indexed by row then column.
        /// Only cells where `cells[row][col]` is true have meaningful colors.
        public let colors: [[Color]]

        /// Background color for the identicon.
        public let backgroundColor: Color

        /// Grid size (number of rows/columns).
        public let gridSize: Int
    }

    // MARK: - Color Palette

    /// Bright colors optimized for dark backgrounds.
    /// Matches the style seen in Android Sideband identicons.
    private static let palette: [Color] = [
        Color(red: 1.0, green: 0.4, blue: 0.6),   // Pink
        Color(red: 0.4, green: 0.8, blue: 0.4),   // Green
        Color(red: 1.0, green: 0.85, blue: 0.3),  // Yellow
        Color(red: 0.6, green: 0.4, blue: 0.9),   // Purple
        Color(red: 0.95, green: 0.95, blue: 0.95),// White
        Color(red: 0.3, green: 0.7, blue: 1.0),   // Cyan
        Color(red: 1.0, green: 0.5, blue: 0.3),   // Orange
        Color(red: 0.5, green: 0.9, blue: 0.8),   // Teal
        Color(red: 1.0, green: 0.6, blue: 0.8),   // Light Pink
        Color(red: 0.7, green: 0.9, blue: 0.4),   // Lime
        Color(red: 0.9, green: 0.7, blue: 1.0),   // Lavender
        Color(red: 0.3, green: 0.9, blue: 0.6),   // Mint
        Color(red: 1.0, green: 0.7, blue: 0.5),   // Peach
        Color(red: 0.6, green: 0.8, blue: 1.0),   // Light Blue
        Color(red: 0.9, green: 0.4, blue: 0.4),   // Coral
        Color(red: 0.8, green: 0.6, blue: 0.4),   // Tan
    ]

    /// Dark background colors for contrast.
    private static let backgroundPalette: [Color] = [
        Color(red: 0.12, green: 0.12, blue: 0.14),  // Dark gray
        Color(red: 0.10, green: 0.12, blue: 0.16),  // Dark blue-gray
        Color(red: 0.14, green: 0.12, blue: 0.14),  // Dark purple-gray
        Color(red: 0.12, green: 0.14, blue: 0.12),  // Dark green-gray
    ]

    // MARK: - Generation

    /// Generate an identicon pattern from hash data.
    ///
    /// - Parameters:
    ///   - hash: 16-byte identity hash (or any Data, uses first 16 bytes)
    ///   - gridSize: Size of the grid (default 5x5)
    /// - Returns: Generated pattern with cells, colors, and background
    public static func generate(from hash: Data, gridSize: Int = 5) -> Pattern {
        // Ensure we have enough bytes, pad with zeros if needed
        var bytes = [UInt8](hash)
        while bytes.count < 16 {
            bytes.append(0)
        }

        // Calculate half width for symmetry (include middle column for odd sizes)
        let halfWidth = (gridSize + 1) / 2

        // Generate cells - use hash bytes to determine filled positions
        var cells = [[Bool]](repeating: [Bool](repeating: false, count: gridSize), count: gridSize)

        // Use first bytes for cell pattern
        var byteIndex = 0
        var bitIndex = 0

        for row in 0..<gridSize {
            for col in 0..<halfWidth {
                // Get bit from hash
                let byte = bytes[byteIndex % bytes.count]
                let bit = (byte >> (7 - bitIndex)) & 1
                let filled = bit == 1

                // Set cell and its mirror
                cells[row][col] = filled
                let mirrorCol = gridSize - 1 - col
                if mirrorCol != col {
                    cells[row][mirrorCol] = filled
                }

                // Advance to next bit
                bitIndex += 1
                if bitIndex >= 8 {
                    bitIndex = 0
                    byteIndex += 1
                }
            }
        }

        // Generate colors for each cell
        var colors = [[Color]](repeating: [Color](repeating: .clear, count: gridSize), count: gridSize)

        // Use remaining bytes for colors, cycling through palette
        let colorSeed = Int(bytes[4]) ^ Int(bytes[5]) ^ Int(bytes[6])

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                if cells[row][col] {
                    // Deterministic color selection based on position and hash
                    let colorIndex = (colorSeed + row * gridSize + col + Int(bytes[(row + col) % bytes.count])) % palette.count
                    colors[row][col] = palette[colorIndex]
                }
            }
        }

        // Background color from last bytes
        let bgIndex = Int(bytes[15]) % backgroundPalette.count
        let backgroundColor = backgroundPalette[bgIndex]

        return Pattern(
            cells: cells,
            colors: colors,
            backgroundColor: backgroundColor,
            gridSize: gridSize
        )
    }

    /// Generate a pattern using a hex string hash.
    ///
    /// - Parameters:
    ///   - hexHash: Hex string representation of hash
    ///   - gridSize: Size of the grid (default 5x5)
    /// - Returns: Generated pattern
    public static func generate(fromHex hexHash: String, gridSize: Int = 5) -> Pattern {
        let hash = hexToData(hexHash)
        return generate(from: hash, gridSize: gridSize)
    }

    // MARK: - Helpers

    /// Convert hex string to Data.
    private static func hexToData(_ hex: String) -> Data {
        var data = Data()
        var temp = ""

        for char in hex {
            temp += String(char)
            if temp.count == 2 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                }
                temp = ""
            }
        }

        return data
    }
}

// MARK: - Preview Support

extension IdenticonGenerator {
    /// Generate a random pattern for previews.
    public static func randomPattern(gridSize: Int = 5) -> Pattern {
        var randomBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            randomBytes[i] = UInt8.random(in: 0...255)
        }
        return generate(from: Data(randomBytes), gridSize: gridSize)
    }
}
