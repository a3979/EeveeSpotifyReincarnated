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

    /// Causal positive energy change + normalized autocorrelation of onsets.
    /// Takes an offline RMS envelope, typically 50 samples per second. Unlike
    /// online pulse gaps, autocorrelation examines multiple beats together.
    /// It intentionally returns unknown on silence/unreliable material.
    static func estimateTempo(energy: [Double], envelopeHz: Double) -> MixRebuildTempo {
        guard envelopeHz.isFinite, (15...200).contains(envelopeHz),
              energy.count >= Int(envelopeHz * 6) else { return .unknown }
        var onset = [Double](repeating: 0, count: energy.count)
        var baseline = 0.0
        for i in energy.indices {
            let sample = energy[i].isFinite ? max(0, min(1, energy[i])) : 0
            let last = i == 0 ? 0 : (energy[i - 1].isFinite ? max(0, min(1, energy[i - 1])) : 0)
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
