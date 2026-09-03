//
//  VoiceWaveformBars.swift
//  ColumbaApp
//
//  A small, static peak-bar waveform for voice messages (draft preview and
//  bubble). Renders an array of normalized [0, 1] peaks as vertical bars; a
//  playback progress (0...1) tints the played portion with the accent color.
//
//  The waveform is FLEXIBLE horizontally: it fills the remaining width of its
//  row (Android parity - the Android bubble gives the waveform `weight(1f)`),
//  so the bars scale to fit the available space instead of demanding a fixed
//  intrinsic width. A fixed-width waveform (the old behavior) overflows a
//  narrow "sent" bubble (which reserves a Spacer for the avatar gap), wrapping
//  the progress text (taller bubble) and shifting the play button's hit region
//  (taps miss, no audio). Measuring with a GeometryReader and dividing the
//  measured width across the bars makes overflow impossible at any width.
//

import SwiftUI

/// Renders a normalized peak array as vertical bars.
public struct VoiceWaveformBars: View {
    /// Normalized peaks, each in [0, 1] (height of the bar).
    let peaks: [Float]
    /// Playback progress in [0, 1]; bars at or below this index are "played".
    var progress: CGFloat = 0
    /// Gap between bars. The bar width is whatever the measured row width
    /// leaves after the gaps, so this only controls the bar-to-gap ratio.
    var barSpacing: CGFloat = 2
    var color: Color = Theme.textSecondary
    var playedColor: Color = Theme.accentColor

    public init(peaks: [Float], progress: CGFloat = 0) {
        self.peaks = peaks
        self.progress = progress
    }

    public var body: some View {
        GeometryReader { geo in
            let count = peaks.count
            // Bars fill the measured width; each slot is (width - gaps)/count.
            // Clamp to a 1pt minimum so a very narrow row still renders.
            let barWidth = count > 0
                ? max(1, (geo.size.width - barSpacing * CGFloat(count - 1)) / CGFloat(count))
                : 0
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { index, peak in
                    Capsule()
                        .fill(index < Int(progress * CGFloat(peaks.count)) ? playedColor : color)
                        .frame(width: barWidth, height: max(3, CGFloat(peak) * 28))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: 30)
        // Claim the remaining row width (the flexible element in the row).
        .frame(maxWidth: .infinity)
    }
}

/// A default flat waveform used until the real peaks are computed (the player
/// fills the waveform cache asynchronously; see `VoiceMessagePlayer.waveform`).
public enum VoiceWaveform {
    /// `n` bars at a flat midpoint, used as a placeholder before peaks load.
    /// The default matches the real waveform's 40-bar count
    /// (`OggOpusWaveform.bars`) so the row width does not shift when the real
    /// peaks arrive.
    public static func placeholder(bars: Int = 40) -> [Float] {
        Array(repeating: 0.5, count: bars)
    }
}
