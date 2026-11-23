import Foundation

struct LocalMixGainPair: Equatable {
    let outgoing: Double
    let incoming: Double
}


enum LocalMixBlendStrategy: String, Equatable {
    case tempoPaced = "Tempo-paced blend"
    case smoothFade = "Smooth crossfade"
    case quickFade = "Short handoff"
    case manual = "Manual transition"
}

struct LocalMixTransitionPlan: Equatable {
    let duration: Double
    let tempoRate: Float?
    let strategy: LocalMixBlendStrategy
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
        // Clamping a wildly different BPM to +/-10% gives the UI a false
        // "tempo synced" result and usually sounds worse than a plain fade.
        // Don't stretch unless the two tempos really are close enough.
        guard (0.90...1.10).contains(ratio) else { return nil }
        return Float(ratio)
    }

    /// An adaptive transition is only an audio-envelope/tempo plan, not an
    /// Apple Music style downbeat detector. A BPM number alone cannot identify
    /// beat phase, and protected Spotify streams are not available as decks.
    /// For local files we *do* have two independent AVAudioPlayerNodes, so the
    /// planned fade is an actual audible overlap.
    static func automaticPlan(
        outgoingBPM: Double,
        incomingBPM: Double,
        requestedSeconds: Double,
        remaining: Double,
        outroTrim: Double,
        syncTempo: Bool
    ) -> LocalMixTransitionPlan {
        let requested = requestedSeconds.isFinite ? max(0.25, requestedSeconds) : 8
        let validTempos = outgoingBPM.isFinite && incomingBPM.isFinite &&
            (65...180).contains(outgoingBPM) && (65...180).contains(incomingBPM)
        let rate = syncTempo && validTempos
            ? tempoRate(outgoingBPM: outgoingBPM, incomingBPM: incomingBPM) : nil

        let strategy: LocalMixBlendStrategy
        let desired: Double
        if let _ = rate {
            // Eight beats at the outgoing tempo makes musically sized fades.
            // Without a downbeat phase, we deliberately call this tempo-paced,
            // not beat-aligned or phrase-synchronized.
            strategy = .tempoPaced
            desired = min(requested, max(2.0, 480.0 / outgoingBPM))
        } else if validTempos && abs(log(outgoingBPM / incomingBPM)) > 0.25 {
            strategy = .quickFade
            desired = min(requested, 2.0)
        } else {
            strategy = .smoothFade
            desired = min(requested, validTempos ? 4.0 : 6.0)
        }
        return LocalMixTransitionPlan(
            duration: transitionDuration(requested: desired, remaining: remaining, outroTrim: outroTrim),
            tempoRate: rate,
            strategy: strategy
        )
    }
}
