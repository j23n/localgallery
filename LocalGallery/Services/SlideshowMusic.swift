import Foundation
import AVFoundation

/// One of six "thematic music" options surfaced in the slideshow's more menu.
/// Stored via `@AppStorage("slideshowMusicTheme")` so the choice persists.
///
/// Each theme combines a chord progression and key with a distinct **timbre**
/// (partial mix, attack envelope, LFO, detune, optional arpeggio) so the six
/// options sound meaningfully different — not just key-shifted pads.
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
        case .bright:  return "Open major pad with shimmer"
        case .hush:    return "Quiet airy drone"
        case .folk:    return "Plucked arpeggios"
        case .drift:   return "Wide-detuned chorus pad"
        case .hymn:    return "Reverent organ chords"
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
        case .hymn:    return 52 // E3 — organ in lower register
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
            // D – A – G – Dsus4 (broken into 4-note arpeggios)
            return [(0, [0, 4, 7, 12]), (7, [0, 4, 7, 12]), (5, [0, 4, 7, 12]), (0, [0, 5, 7, 12])]
        case .drift:
            // Gmaj7 – Aadd9 – Em9 – Cmaj7 (lydian-ish color)
            return [(0, [0, 4, 7, 11]), (2, [0, 4, 7, 14]), (-3, [0, 3, 7, 10, 14]), (-7, [0, 4, 7, 11])]
        case .hymn:
            // Em – C – G – D
            return [(0, [0, 3, 7]), (-4, [0, 4, 7]), (3, [0, 4, 7]), (-2, [0, 4, 7])]
        }
    }

    /// Seconds per chord. Folk uses a tighter cycle so the arpeggios feel
    /// rhythmic rather than meandering.
    fileprivate var chordDuration: Double {
        switch self {
        case .wistful: return 6.0
        case .bright:  return 4.5
        case .hush:    return 7.0
        case .folk:    return 4.0
        case .drift:   return 7.5
        case .hymn:    return 6.5
        }
    }

    fileprivate var timbre: Timbre {
        switch self {
        case .wistful:
            return Timbre(
                partials: [Partial(multiplier: 1.0, gain: 1.0), Partial(multiplier: 0.5, gain: 0.45)],
                attack: 3.0,
                lfoFrequency: 0.07, lfoDepth: 0.22,
                detune: 0.04,
                arp: nil,
                outputGain: 0.45
            )
        case .bright:
            return Timbre(
                partials: [
                    Partial(multiplier: 1.0, gain: 1.0),
                    Partial(multiplier: 2.0, gain: 0.32),
                    Partial(multiplier: 3.0, gain: 0.16)
                ],
                attack: 1.5,
                lfoFrequency: 0.12, lfoDepth: 0.18,
                detune: 0.0,
                arp: nil,
                outputGain: 0.40
            )
        case .hush:
            return Timbre(
                partials: [Partial(multiplier: 1.0, gain: 0.55), Partial(multiplier: 0.5, gain: 0.30)],
                attack: 5.0,
                lfoFrequency: 0.04, lfoDepth: 0.40,
                detune: 0.0,
                arp: nil,
                outputGain: 0.28 // significantly quieter than other themes
            )
        case .folk:
            return Timbre(
                partials: [
                    Partial(multiplier: 1.0, gain: 1.0),
                    Partial(multiplier: 2.0, gain: 0.35),
                    Partial(multiplier: 3.0, gain: 0.16)
                ],
                attack: 0.02, // pluck — near-instant attack
                lfoFrequency: 0.0, lfoDepth: 0.0, // no breathing; rhythm carries it
                detune: 0.0,
                arp: ArpConfig(interval: 0.5, decay: 1.6),
                outputGain: 0.55
            )
        case .drift:
            return Timbre(
                partials: [
                    Partial(multiplier: 1.0, gain: 1.0),
                    Partial(multiplier: 0.5, gain: 0.40),
                    Partial(multiplier: 2.0, gain: 0.18)
                ],
                attack: 4.0,
                lfoFrequency: 0.05, lfoDepth: 0.25,
                detune: 0.15, // chorusy
                arp: nil,
                outputGain: 0.42
            )
        case .hymn:
            return Timbre(
                partials: [
                    Partial(multiplier: 1.0, gain: 1.0),
                    Partial(multiplier: 2.0, gain: 0.70),
                    Partial(multiplier: 3.0, gain: 0.45),
                    Partial(multiplier: 4.0, gain: 0.22)
                ],
                attack: 0.5,
                lfoFrequency: 0.0, lfoDepth: 0.0, // organ — steady, no breathing
                detune: 0.0,
                arp: nil,
                outputGain: 0.45
            )
        }
    }
}

// MARK: - Timbre

fileprivate struct Partial: Sendable {
    /// Multiplier on the fundamental — 1.0 = fundamental, 2.0 = octave above,
    /// 0.5 = octave below.
    let multiplier: Double
    let gain: Float
}

fileprivate struct ArpConfig: Sendable {
    /// Seconds between arp note onsets.
    let interval: Double
    /// Seconds for each note's exponential amplitude decay.
    let decay: Double
}

fileprivate struct Timbre: Sendable {
    let partials: [Partial]
    /// Seconds for the per-chord amplitude swell at chord start.
    let attack: Double
    /// LFO frequency in Hz; 0 disables breathing.
    let lfoFrequency: Double
    /// LFO modulation depth (0..1). Centred at 1; depth 0.2 means amplitude
    /// breathes between 0.8× and 1.0×.
    let lfoDepth: Float
    /// Detune in semitones — voices are spread ±detune/2 around the chord
    /// tone for a chorus effect.
    let detune: Float
    /// Optional arpeggiator. When set, only one chord tone plays at a time,
    /// cycling through the chord intervals every `interval` seconds.
    let arp: ArpConfig?
    /// Final output scaler. Lets quieter themes (hush) sit in the mix.
    let outputGain: Float
}

// MARK: - Pure synthesis

/// Stateless renderer that produces one full progression cycle as raw float32
/// PCM samples. Pure — runs anywhere, including off-MainActor — so the disk
/// pre-warm task can build all six themes in the background without touching
/// the player.
enum SlideshowMusicSynth: Sendable {
    static let sampleRate: Double = 44_100

    /// Render one looped progression cycle for `theme` at `sampleRate`.
    static func render(theme: SlideshowMusicTheme, sampleRate: Double = sampleRate) -> [Float] {
        let chordSeconds = theme.chordDuration
        let chordCount = theme.progression.count
        let totalSeconds = chordSeconds * Double(chordCount)
        let frameCount = Int(totalSeconds * sampleRate)
        var out = [Float](repeating: 0, count: frameCount)

        let timbre = theme.timbre
        let chordSamples = Int(chordSeconds * sampleRate)
        let crossfadeSamples = timbre.arp == nil ? chordSamples / 4 : 0

        for i in 0..<frameCount {
            let chordIdx = i / chordSamples
            let withinChord = i % chordSamples
            let curr = theme.progression[chordIdx]
            let next = theme.progression[(chordIdx + 1) % chordCount]
            let currMidi = theme.rootMidi + curr.0
            let nextMidi = theme.rootMidi + next.0

            let t = Double(i) / sampleRate
            let chordT = Double(withinChord) / sampleRate
            var sample: Float = 0

            if let arp = timbre.arp {
                let noteIdx = Int(chordT / arp.interval)
                let noteStart = Double(noteIdx) * arp.interval
                let noteT = chordT - noteStart
                if noteIdx < curr.1.count * 4 {
                    let interval = curr.1[noteIdx % curr.1.count]
                    sample += pluckSample(
                        midi: currMidi + interval,
                        time: t,
                        noteT: noteT,
                        decay: arp.decay,
                        timbre: timbre
                    )
                }
            } else {
                var wCurr: Float = chordEnvelope(chordT: chordT, attack: timbre.attack)
                var wNext: Float = 0
                if withinChord >= chordSamples - crossfadeSamples {
                    let crossT = Float(withinChord - (chordSamples - crossfadeSamples)) / Float(crossfadeSamples)
                    wCurr *= (1 - crossT)
                    wNext = crossT * chordEnvelope(chordT: 0, attack: 0.05)
                }
                sample += padChord(midiRoot: currMidi, intervals: curr.1, time: t, timbre: timbre) * wCurr
                if wNext > 0 {
                    sample += padChord(midiRoot: nextMidi, intervals: next.1, time: t, timbre: timbre) * wNext
                }
            }

            if timbre.lfoFrequency > 0 {
                let lfo = Float(1.0 - Double(timbre.lfoDepth)) + timbre.lfoDepth * Float(0.5 + 0.5 * sin(2 * .pi * timbre.lfoFrequency * t))
                sample *= lfo
            }
            out[i] = tanh(sample) * timbre.outputGain
        }
        return out
    }

    fileprivate static func chordEnvelope(chordT: Double, attack: Double) -> Float {
        guard attack > 0 else { return 1 }
        if chordT >= attack { return 1 }
        return Float(chordT / attack)
    }

    fileprivate static func padChord(midiRoot: Int, intervals: [Int], time: Double, timbre: Timbre) -> Float {
        var s: Float = 0
        for interval in intervals {
            let baseFreq = midiToHz(midiRoot + interval)
            s += voice(baseFreq: baseFreq, time: time, timbre: timbre)
        }
        return s / Float(max(1, intervals.count))
    }

    fileprivate static func pluckSample(
        midi: Int, time: Double, noteT: Double, decay: Double, timbre: Timbre
    ) -> Float {
        guard noteT >= 0 else { return 0 }
        let baseFreq = midiToHz(midi)
        let attack = chordEnvelope(chordT: noteT, attack: timbre.attack)
        let decayEnv = Float(exp(-noteT / decay))
        return voice(baseFreq: baseFreq, time: time, timbre: timbre) * attack * decayEnv
    }

    fileprivate static func voice(baseFreq: Double, time: Double, timbre: Timbre) -> Float {
        let detuneVoices: [Double]
        if timbre.detune > 0 {
            let half = Double(timbre.detune) / 2
            detuneVoices = [0.0, half, -half]
        } else {
            detuneVoices = [0.0]
        }
        var s: Float = 0
        for cents in detuneVoices {
            let freq = baseFreq * pow(2.0, cents / 12.0)
            for partial in timbre.partials {
                let f = freq * partial.multiplier
                s += Float(sin(2 * .pi * f * time)) * partial.gain
            }
        }
        let voiceCount = Float(detuneVoices.count)
        let partialGainSum = timbre.partials.map(\.gain).reduce(0, +)
        return s / max(1, voiceCount * partialGainSum)
    }

    fileprivate static func midiToHz(_ midi: Int) -> Double {
        440.0 * pow(2.0, Double(midi - 69) / 12.0)
    }
}

// MARK: - Disk cache

/// On-disk cache of pre-rendered theme PCM data. Each theme writes a raw
/// float32 mono buffer to `Caches/slideshow-music/<theme>-v<N>.pcm`. The file
/// is just the sample bytes — the format is implied by the cache version.
///
/// Pre-warmed once at app launch via `prewarmAll()` on a low-priority detached
/// task so subsequent `play(theme:)` calls memcpy from disk instead of
/// re-running the synth loop.
enum SlideshowMusicCache {
    /// Bump when synthesis changes substantively to invalidate stale .pcm files.
    static let version = 1
    static let sampleRate: Double = SlideshowMusicSynth.sampleRate

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("slideshow-music", isDirectory: true)
    }

    static func cachedFileURL(for theme: SlideshowMusicTheme) -> URL {
        cacheDirectory.appendingPathComponent("\(theme.rawValue)-v\(version).pcm")
    }

    /// Load cached samples, or nil on miss.
    static func loadSamples(for theme: SlideshowMusicTheme) -> [Float]? {
        let url = cachedFileURL(for: theme)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 0,
              data.count % MemoryLayout<Float>.size == 0
        else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: count))
        }
    }

    /// Persist `samples` for `theme`. Atomic write so a crashed render leaves
    /// no half-written file behind.
    static func write(samples: [Float], for theme: SlideshowMusicTheme) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let url = cachedFileURL(for: theme)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Swift 6 strict concurrency: capture URL outside the autoclosure.
            let path = url.path
            Log.ui.warning("Failed to write music cache \(path): \(error.localizedDescription)")
        }
    }

    /// Render every theme that doesn't already have a current cache file.
    /// Safe to call multiple times — already-cached themes are skipped.
    /// `.utility` priority so the work actually completes promptly after
    /// app launch (`.background` was getting deferred long enough that the
    /// first slideshow open still hit the inline-synth fallback).
    static func prewarmAll() async {
        await Task.detached(priority: .utility) {
            let total = SlideshowMusicTheme.allCases.count
            var rendered = 0
            var skipped = 0
            let overall = CFAbsoluteTimeGetCurrent()
            for theme in SlideshowMusicTheme.allCases {
                let url = cachedFileURL(for: theme)
                if FileManager.default.fileExists(atPath: url.path) {
                    skipped += 1
                    continue
                }
                let start = CFAbsoluteTimeGetCurrent()
                let samples = SlideshowMusicSynth.render(theme: theme)
                write(samples: samples, for: theme)
                rendered += 1
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                Log.ui.info("Music: rendered '\(theme.rawValue)' (\(samples.count) samples) in \(String(format: "%.0f", elapsed))ms")
            }
            let overallElapsed = (CFAbsoluteTimeGetCurrent() - overall) * 1000
            Log.ui.info("Music prewarm: \(rendered) rendered, \(skipped) cached, \(total) total in \(String(format: "%.0f", overallElapsed))ms")
        }.value
    }
}

// MARK: - Player

/// Drives ambient pad audio for the memory slideshow. Built around a single
/// `AVAudioEngine` + `AVAudioPlayerNode` that loops a generated PCM buffer.
/// Theme switches load the buffer from `SlideshowMusicCache` (synthesizing
/// in-line as a fallback if the cache file isn't there yet).
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

    /// Async so the buffer load (potentially a cold synth render on cache
    /// miss) happens on a background task rather than blocking the main
    /// actor — the slideshow's first frame paints while we're still
    /// rendering audio. Engine.start + `scheduleBuffer + play` still run on
    /// main once the samples are ready.
    func play(theme: SlideshowMusicTheme) async {
        if currentTheme == theme && isRunning { return }
        currentTheme = theme
        let sampleRate = format.sampleRate
        let samples = await Task.detached(priority: .userInitiated) { () -> [Float]? in
            if let cached = SlideshowMusicCache.loadSamples(for: theme) {
                return cached
            }
            let rendered = SlideshowMusicSynth.render(theme: theme, sampleRate: sampleRate)
            SlideshowMusicCache.write(samples: rendered, for: theme)
            return rendered
        }.value
        guard let samples, let buffer = makeBuffer(from: samples) else { return }
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

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
