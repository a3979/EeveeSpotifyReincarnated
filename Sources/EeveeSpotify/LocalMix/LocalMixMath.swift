import Foundation

struct LocalMixGainPair: Equatable {
    let outgoing: Double
    let incoming: Double
}

/// Pure transition math shared by the audio engine and its regression tests.
enum LocalMixMath {
    static func gains(curve: String, progress: Double) -> LocalMixGainPair {
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        switch curve {
        case "Linear":
            return LocalMixGainPair(outgoing: 1 - p, incoming: p)
        case "S-curve":
            let smooth = p * p * (3 - 2 * p)
            return LocalMixGainPair(
                outgoing: cos(smooth * .pi / 2),
                incoming: sin(smooth * .pi / 2)
            )
        case "Hard cut":
            return p < 0.5
                ? LocalMixGainPair(outgoing: 1, incoming: 0)
                : LocalMixGainPair(outgoing: 0, incoming: 1)
        default: // Equal power is the safe default for unknown/older project values.
            return LocalMixGainPair(
                outgoing: cos(p * .pi / 2),
                incoming: sin(p * .pi / 2)
            )
        }
    }

    /// Never schedules a fade longer than the usable outgoing section.
    /// A short remaining section still receives a minimal 250 ms handoff.
    static func transitionDuration(requested: Double, remaining: Double, outroTrim: Double) -> Double {
        let requestedValue = requested.isFinite ? requested : 8
        let remainingValue = remaining.isFinite ? remaining : requestedValue
        let trimValue = outroTrim.isFinite ? max(0, outroTrim) : 0
        let desired = max(0.25, requestedValue)
        let available = max(0.25, remainingValue - trimValue)
        return min(desired, available)
    }

    /// Return a bounded incoming playback rate for tempo matching.
    /// Nil means the analyzer did not produce two usable tempo estimates.
    static func tempoRate(outgoingBPM: Double, incomingBPM: Double) -> Float? {
        guard outgoingBPM.isFinite, incomingBPM.isFinite,
              (65...180).contains(outgoingBPM),
              (65...180).contains(incomingBPM) else { return nil }
        let ratio = outgoingBPM / incomingBPM
        guard ratio.isFinite else { return nil }
        return Float(min(1.10, max(0.90, ratio)))
    }
}
