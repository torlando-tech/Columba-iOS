//
//  VoiceWaveformBars.swift
//  ColumbaApp
//
//  A small, static peak-bar waveform for voice messages (draft preview and
//  bubble). Renders an array of normalized [0, 1] peaks as vertical bars; a
//  playback progress (0...1) tints the played portion with the accent color.
//

import SwiftUI

/// Renders a normalized peak array as vertical bars.
public struct VoiceWaveformBars: View {
    /// Normalized peaks, each in [0, 1] (height of the bar).
    let peaks: [Float]
    /// Playback progress in [0, 1]; bars at or below this index are "played".
    var progress: CGFloat = 0
    var barSpacing: CGFloat = 2
    var color: Color = Theme.textSecondary
    var playedColor: Color = Theme.accentColor

    public init(peaks: [Float], progress: CGFloat = 0) {
        self.peaks = peaks
        self.progress = progress
    }

    public var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(Array(peaks.enumerated()), id: \.offset) { index, peak in
                Capsule()
                    .fill(index < Int(progress * CGFloat(peaks.count)) ? playedColor : color)
                    .frame(width: 2.5, height: max(3, CGFloat(peak) * 28))
            }
        }
        .frame(height: 30)
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
