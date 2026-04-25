import Foundation
import AVFoundation

/// One of six "thematic music" options surfaced in the slideshow's top pill.
/// Stored via `@AppStorage("slideshowMusicTheme")` so the choice persists.
///
/// We synthesize each theme on the fly with `AVAudioEngine` rather than ship
/// audio assets — every theme is built from a few sine partials over a slow
/// chord progression, distinguished by key, register, and tempo. The result
/// is unobtrusive ambient pad music that sits behind the photos.
enum SlideshowMusicTheme: String, CaseIterable, Identifiable, Sendable {
    case wistful
    case bright
    case hush
    case folk
    case drift
    case hymn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wistful: return "Wistful"
        case .bright:  return "Bright"
        case .hush:    return "Hush"
        case .folk:    return "Folk"
        case .drift:   return "Drift"
        case .hymn:    return "Hymn"
        }
    }

    /// Short description used in the picker subtitle.
    var blurb: String {
        switch self {
        case .wistful: return "Slow minor pad"
        case .bright:  return "Open major chords"
        case .hush:    return "Quiet airy drone"
        case .folk:    return "Mixolydian warmth"
        case .drift:   return "Floating lydian"
        case .hymn:    return "Reverent dorian"
        }
    }

    /// Root MIDI note for the chord progression (C4 = 60).
    fileprivate var rootMidi: Int {
        switch self {
        case .wistful: return 57 // A3
        case .bright:  return 60 // C4
        case .hush:    return 65 // F4
        case .folk:    return 62 // D4
        case .drift:   return 67 // G4
        case .hymn:    return 64 // E4
        }
    }

    /// Chord progression as semitone offsets and chord intervals over the root.
    /// Each tuple is (root offset, [chord tone offsets]).
    fileprivate var progression: [(Int, [Int])] {
        switch self {
        case .wistful:
            // Am – Fmaj7 – Cmaj – Em
            return [(0, [0, 3, 7]), (-4, [0, 4, 7, 11]), (3, [0, 4, 7]), (7, [0, 3, 7])]
        case .bright:
            // C – G – Am – F
            return [(0, [0, 4, 7]), (7, [0, 4, 7]), (9, [0, 3, 7]), (5, [0, 4, 7])]
        case .hush:
            // Fmaj7 – Dm7 – Bb – Gm
            return [(0, [0, 4, 7, 11]), (-3, [0, 3, 7, 10]), (5, [0, 4, 7]), (2, [0, 3, 7])]
        case .folk:
            // D – A – G – Dsus4
            return [(0, [0, 4, 7]), (7, [0, 4, 7]), (5, [0, 4, 7]), (0, [0, 5, 7])]
        case .drift:
            // Gmaj7 – Aadd9 – Em9 – Cmaj7 (lydian-ish color)
            return [(0, [0, 4, 7, 11]), (2, [0, 4, 7, 14]), (-3, [0, 3, 7, 10, 14]), (-7, [0, 4, 7, 11])]
        case .hymn:
            // Em – C – G – D
            return [(0, [0, 3, 7]), (-4, [0, 4, 7]), (3, [0, 4, 7]), (-2, [0, 4, 7])]
        }
    }

    /// Seconds per chord — slower themes feel more contemplative.
    fileprivate var chordDuration: Double {
        switch self {
        case .wistful: return 6.0
        case .bright:  return 4.5
        case .hush:    return 7.0
        case .folk:    return 5.0
        case .drift:   return 7.5
        case .hymn:    return 6.5
        }
    }
}

/// Drives ambient pad audio for the memory slideshow. Built around a single
/// `AVAudioEngine` + `AVAudioPlayerNode` that loops a generated PCM buffer.
/// Theme switches rebuild the buffer in place; the engine keeps running so
/// playback doesn't gap when the user picks a new theme mid-slideshow.
@MainActor
final class SlideshowMusicPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var currentTheme: SlideshowMusicTheme?
    private var isRunning = false

    init() {
        // 32-bit float, mono, 44.1 kHz. Mono is enough for ambient pads and
        // keeps buffer generation cheap.
        self.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.18
    }

    func play(theme: SlideshowMusicTheme) {
        if currentTheme == theme && isRunning { return }
        currentTheme = theme
        // Rebuild buffer for the new theme.
        guard let buffer = renderBuffer(for: theme) else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()
        isRunning = true
    }

    func stop() {
        player.stop()
        engine.stop()
        isRunning = false
    }

    // MARK: Synthesis

    /// Renders one full progression cycle as a single PCM buffer that we'll
    /// loop. Each chord crossfades into the next, and a slow LFO modulates
    /// amplitude so the pad breathes instead of sitting at constant volume.
    private func renderBuffer(for theme: SlideshowMusicTheme) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let chordSeconds = theme.chordDuration
        let chordCount = theme.progression.count
        let totalSeconds = chordSeconds * Double(chordCount)
        let frameCount = AVAudioFrameCount(totalSeconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        let chordSamples = Int(chordSeconds * sampleRate)
        let crossfadeSamples = chordSamples / 4
        let lfoFrequency = 0.07 // very slow breathing, ~14s per cycle

        for i in 0..<Int(frameCount) {
            let chordIdx = i / chordSamples
            let withinChord = i % chordSamples
            let curr = theme.progression[chordIdx]
            let next = theme.progression[(chordIdx + 1) % chordCount]
            let currMidi = theme.rootMidi + curr.0
            let nextMidi = theme.rootMidi + next.0

            // Crossfade weights between current and next chord at the tail.
            var wCurr: Float = 1
            var wNext: Float = 0
            if withinChord >= chordSamples - crossfadeSamples {
                let t = Float(withinChord - (chordSamples - crossfadeSamples)) / Float(crossfadeSamples)
                wCurr = 1 - t
                wNext = t
            }

            let t = Double(i) / sampleRate
            var sample: Float = 0
            sample += synth(midiRoot: currMidi, intervals: curr.1, time: t) * wCurr
            sample += synth(midiRoot: nextMidi, intervals: next.1, time: t) * wNext

            // Slow amplitude LFO so the pad breathes; never goes to zero.
            let lfo = Float(0.78 + 0.22 * sin(2 * .pi * lfoFrequency * t))
            sample *= lfo
            // Soft clip to avoid harsh peaks if partials align.
            sample = tanh(sample)
            channel[i] = sample * 0.45
        }
        return buffer
    }

    /// Produces one sample at `time` for a chord defined by a root midi note
    /// plus a list of interval offsets. Each note is two stacked sine partials
    /// (fundamental + octave-down sub) so the pad has body without sounding
    /// like a single lonely beep.
    private func synth(midiRoot: Int, intervals: [Int], time: Double) -> Float {
        var s: Float = 0
        for interval in intervals {
            let midi = midiRoot + interval
            let freq = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
            let fundamental = sin(2 * .pi * freq * time)
            let sub = sin(2 * .pi * (freq / 2) * time) * 0.45
            s += Float(fundamental + sub)
        }
        return s / Float(max(1, intervals.count) * 2)
    }
}
