import Foundation

/// New Mix engine, independent of Spotify's Premium playlist Mix service.
/// This module has no UIKit/AVFoundation dependencies and can run in CI.
enum MixRebuildStyle: String, Codable, Equatable, Sendable {
    case tempoPaced
    case smooth
    case quick
}

struct MixRebuildPlan: Equatable, Sendable {
    let style: MixRebuildStyle
    let seconds: Double
    let incomingRate: Float
}

struct MixRebuildTempo: Codable, Equatable, Sendable {
    let bpm: Double
    let confidence: Double

    static let unknown = MixRebuildTempo(bpm: 0, confidence: 0)
}

/// Beat-grid metadata mirrors the useful parts of Spotify's native
/// playlistmixing.extensions.mixbeats payload. Times are seconds from track start.
struct MixRebuildBeat: Codable, Equatable, Sendable {
    let time: Double
    let duration: Double
    let beatInBar: Int
    let beatConfidence: Double
    let downbeatConfidence: Double
}

struct MixRebuildBeatGrid: Codable, Equatable, Sendable {
    let beats: [MixRebuildBeat]
    let beatsPerBar: Int
    let bpm: Double
    let confidence: Double
}

struct MixRebuildOverlap: Codable, Equatable, Sendable {
    let outStartPositionMs: Int
    let inStartPositionMs: Int
    let outSpeed: Float
    let inSpeed: Float
    let durationMs: Int
    let durationBars: Int
    let isBeatmatched: Bool
    let bpmA: Double
    let bpmB: Double
    let itemSpeedA: Float
    let itemSpeedB: Float
}

enum MixRebuildCore {
    /// Spotify's preference setter accepts milliseconds, not seconds.
    /// Keep this conversion explicit and covered by regression tests.
    static func crossfadeMilliseconds(seconds: Int) -> Int {
        max(0, min(12, seconds)) * 1000
    }

    /// Equal-power crossfade between *two playing decks*. Changing one deck's
    /// volume without starting a second deck cannot create an audible mix.
    static func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = progress.isFinite ? max(0, min(1, progress)) : 0
        return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
    }

    /// Do not fake beat synchronization: BPM gives tempo, not downbeat phase.
    /// This is a conservative tempo-paced fade, not phrase/beat-grid matching.
    static func plan(
        outgoing: MixRebuildTempo,
        incoming: MixRebuildTempo,
        preferredSeconds: Double,
        availableSeconds: Double
    ) -> MixRebuildPlan {
        let desired = preferredSeconds.isFinite ? max(0.25, min(16, preferredSeconds)) : 6
        let available = availableSeconds.isFinite ? max(0.25, availableSeconds) : desired
        let valid = outgoing.confidence >= 0.28 && incoming.confidence >= 0.28 &&
                    (70...180).contains(outgoing.bpm) && (70...180).contains(incoming.bpm)
        if valid {
            let ratio = outgoing.bpm / incoming.bpm
            // Tempo changes greater than 5% are noticeable and often sound bad.
            if (0.95...1.05).contains(ratio) {
                let beatWindow = 8 * 60 / outgoing.bpm
                return MixRebuildPlan(style: .tempoPaced,
                                      seconds: min(available, min(desired, max(1, beatWindow))),
                                      incomingRate: Float(ratio))
            }
            if ratio < 0.78 || ratio > 1.22 {
                return MixRebuildPlan(style: .quick, seconds: min(available, min(desired, 1.75)), incomingRate: 1)
            }
        }
        return MixRebuildPlan(style: .smooth, seconds: min(available, min(desired, 5)), incomingRate: 1)
    }

    /// Build a local transition from per-track beat grids. No Automix RPC or
    /// Spotify Premium transition recipe is required. When beat grids are absent
    /// or unreliable, return a plain equal-power fade rather than inventing sync.
    static func planOverlap(
        outgoing: MixRebuildBeatGrid?,
        incoming: MixRebuildBeatGrid?,
        outgoingDurationMs: Double,
        preferredSeconds: Double
    ) -> MixRebuildOverlap {
        let desired = preferredSeconds.isFinite ? max(1.0, min(12.0, preferredSeconds)) : 6.0
        let durationMs = outgoingDurationMs.isFinite ? max(0, outgoingDurationMs) : 0
        func fallback() -> MixRebuildOverlap {
            let length = Int(min(desired * 1000, max(1000, durationMs)))
            return MixRebuildOverlap(
                outStartPositionMs: max(0, Int(durationMs) - length),
                inStartPositionMs: 0,
                outSpeed: 1, inSpeed: 1, durationMs: length,
                durationBars: 0, isBeatmatched: false,
                bpmA: 0, bpmB: 0, itemSpeedA: 1, itemSpeedB: 1
            )
        }
        guard let a = outgoing, let b = incoming,
              a.beats.count >= 8, b.beats.count >= 8,
              (2...8).contains(a.beatsPerBar), (2...8).contains(b.beatsPerBar),
              a.confidence >= 0.45, b.confidence >= 0.45,
              a.bpm.isFinite, b.bpm.isFinite,
              (70...180).contains(a.bpm), (70...180).contains(b.bpm),
              durationMs > desired * 1000 + 1000 else { return fallback() }

        let ratio = a.bpm / b.bpm
        guard (0.90...1.10).contains(ratio) else { return fallback() }
        let barSeconds = Double(a.beatsPerBar) * 60.0 / a.bpm
        guard barSeconds.isFinite, barSeconds > 0 else { return fallback() }
        let bars = max(2, min(8, Int((desired / barSeconds).rounded())))
        let overlapSeconds = min(desired, Double(bars) * barSeconds)
        let outTarget = durationMs / 1000.0 - overlapSeconds

        func isDownbeat(_ beat: MixRebuildBeat) -> Bool {
            beat.beatInBar == 0 || beat.downbeatConfidence >= 0.55
        }
        // Never choose an outgoing downbeat so late that the fade cannot
        // finish before the source track ends. The incoming deck is already
        // playing, so a slightly shorter transition is safer than a stalled
        // handoff at end-of-track.
        let latestSafeStart = durationMs / 1000.0 - overlapSeconds * 0.75
        let outCandidates = a.beats.filter {
            $0.time.isFinite && $0.time >= max(0, outTarget - 5) &&
            $0.time <= latestSafeStart &&
            isDownbeat($0) && $0.downbeatConfidence >= 0.35
        }
        let inCandidates = b.beats.filter {
            $0.time.isFinite && $0.time >= 1.0 && $0.time <= 30.0 &&
            isDownbeat($0) && $0.downbeatConfidence >= 0.35
        }
        guard let outBeat = outCandidates.min(by: {
            abs($0.time - outTarget) < abs($1.time - outTarget)
        }), let inBeat = inCandidates.first else { return fallback() }

        let remainingAfterDownbeat = durationMs / 1000.0 - outBeat.time
        let actualOverlapSeconds = min(overlapSeconds, remainingAfterDownbeat)
        guard actualOverlapSeconds >= overlapSeconds * 0.75 else { return fallback() }
        let lengthMs = Int(actualOverlapSeconds * 1000)
        let actualBars = max(1, Int((actualOverlapSeconds / barSeconds).rounded()))
        return MixRebuildOverlap(
            outStartPositionMs: max(0, Int(outBeat.time * 1000)),
            inStartPositionMs: max(0, Int(inBeat.time * 1000)),
            outSpeed: 1,
            inSpeed: Float(ratio),
            durationMs: lengthMs,
            durationBars: actualBars,
            isBeatmatched: true,
            bpmA: a.bpm,
            bpmB: b.bpm,
            itemSpeedA: 1,
            itemSpeedB: 1
        )
    }

    /// Explain why a real PCM envelope cannot produce a reliable BPM.
    /// This is diagnostic, not a fabricated tempo fallback.
    static func tempoSignalDescription(energy: [Double], envelopeHz: Double) -> String {
        guard envelopeHz.isFinite, (15...200).contains(envelopeHz),
              energy.count >= Int(envelopeHz * 6) else {
            return "insufficient or irregular PCM envelope"
        }
        let levels = energy.map { $0.isFinite ? max(0, min(1, $0)) : 0 }
        let high = levels.max() ?? 0
        let low = levels.min() ?? 0
        if high < 0.00005 {
            return String(format: "too quiet: RMS peak %.5f", high)
        }
        let contrast = (high - low) / high
        if high - low < max(0.00003, high * 0.08) {
            return String(format: "low energy contrast: RMS peak %.4f, contrast %.1f%%", high, contrast * 100)
        }
        let scale = 1 / high
        var baseline = 0.0
        var power = 0.0
        for i in levels.indices {
            let v = levels[i] * scale
            let last = i == 0 ? 0 : levels[i - 1] * scale
            let onset = max(0, v - last - baseline * 0.03)
            power += onset * onset
            baseline = baseline * 0.99 + v * 0.01
        }
        if power < 0.02 {
            return String(format: "weak percussive onsets: RMS peak %.4f, onset power %.4f", high, power)
        }
        let tempo = estimateTempo(energy: energy, envelopeHz: envelopeHz)
        if tempo.confidence < 0.28 {
            return String(format: "no stable beat periodicity: RMS peak %.4f, onset power %.3f, sample rate %.1f Hz", high, power, envelopeHz)
        }
        return String(format: "beat periodicity detected: %.1f BPM at confidence %.2f", tempo.bpm, tempo.confidence)
    }

    /// Causal positive energy change + normalized autocorrelation of onsets.
    /// Takes an offline RMS envelope, typically 50 samples per second. Unlike
    /// online pulse gaps, autocorrelation examines multiple beats together.
    /// It intentionally returns unknown on silence/unreliable material.
    static func estimateTempo(energy: [Double], envelopeHz: Double) -> MixRebuildTempo {
        guard envelopeHz.isFinite, (15...200).contains(envelopeHz),
              energy.count >= Int(envelopeHz * 6) else { return .unknown }
        // PCM amplitude depends on Spotify's output volume, AudioUnit gain,
        // and the system route. An absolute onset-energy cutoff rejects quiet
        // but otherwise valid beat trains; normalize by the observed peak.
        // Still reject near-constant envelopes and genuine near-silence.
        let levels = energy.map { $0.isFinite ? max(0, min(1, $0)) : 0 }
        let maximum = levels.max() ?? 0
        let minimum = levels.min() ?? 0
        guard maximum >= 0.00005,
              maximum - minimum >= max(0.00003, maximum * 0.08) else { return .unknown }
        let scale = 1 / maximum

        var onset = [Double](repeating: 0, count: energy.count)
        var baseline = 0.0
        for i in levels.indices {
            let sample = levels[i] * scale
            let last = i == 0 ? 0 : levels[i - 1] * scale
            onset[i] = max(0, sample - last - baseline * 0.03)
            baseline = baseline * 0.99 + sample * 0.01
        }
        let sumEnergy = onset.reduce(0) { $0 + $1 * $1 }
        guard sumEnergy >= 0.02 else { return .unknown }
        let firstLag = max(1, Int((envelopeHz * 60 / 180).rounded()))
        let lastLag = min(onset.count / 4, Int((envelopeHz * 60 / 70).rounded()))
        guard firstLag < lastLag else { return .unknown }

        var bestScore = 0.0
        var bestLag = 0
        for lag in firstLag...lastLag {
            var similarity = 0.0
            var a = 0.0
            var b = 0.0
            for i in lag..<onset.count {
                let x = onset[i], y = onset[i - lag]
                similarity += x * y
                a += x * x
                b += y * y
            }
            let score = similarity / max(1e-9, sqrt(a * b))
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestLag > 0, bestScore >= 0.28 else { return .unknown }
        return MixRebuildTempo(bpm: 60 * envelopeHz / Double(bestLag),
                               confidence: min(1, bestScore))
    }
}
