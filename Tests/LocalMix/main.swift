// Regression coverage for the embedded local two-deck engine.
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("[LocalMix] FAIL: \(message)\n", stderr)
        exit(1)
    }
}
func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.0001) -> Bool {
    abs(a - b) <= tolerance
}

let start = LocalMixMath.gains(curve: "Equal power", progress: 0)
let middle = LocalMixMath.gains(curve: "Equal power", progress: 0.5)
let end = LocalMixMath.gains(curve: "Equal power", progress: 1)
check(close(start.outgoing, 1) && close(start.incoming, 0), "equal-power start")
check(close(end.outgoing, 0) && close(end.incoming, 1), "equal-power end")
check(close(middle.outgoing * middle.outgoing + middle.incoming * middle.incoming, 1),
      "equal-power midpoint preserves energy")

let linear = LocalMixMath.gains(curve: "Linear", progress: 0.25)
check(close(linear.outgoing, 0.75) && close(linear.incoming, 0.25), "linear curve")
let hardCutA = LocalMixMath.gains(curve: "Hard cut", progress: 0.49)
let hardCutB = LocalMixMath.gains(curve: "Hard cut", progress: 0.5)
check(hardCutA.outgoing == 1 && hardCutA.incoming == 0, "hard cut before midpoint")
check(hardCutB.outgoing == 0 && hardCutB.incoming == 1, "hard cut at midpoint")

check(close(LocalMixMath.transitionDuration(requested: 8, remaining: 20, outroTrim: 2), 8),
      "requested transition duration")
check(close(LocalMixMath.transitionDuration(requested: 12, remaining: 5, outroTrim: 1), 4),
      "transition bounded by remaining audio")
check(close(LocalMixMath.transitionDuration(requested: 8, remaining: 0, outroTrim: 0), 0.25),
      "short handoff has safe minimum")

let rate = LocalMixMath.tempoRate(outgoingBPM: 120, incomingBPM: 124)
check(rate != nil && close(Double(rate!), 120.0 / 124.0), "tempo match rate")
check(LocalMixMath.tempoRate(outgoingBPM: 75, incomingBPM: 155) == nil,
      "large tempo mismatch must not be stretched")

let matched = LocalMixMath.automaticPlan(
    outgoingBPM: 120, incomingBPM: 124, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: true
)
check(matched.strategy == .tempoPaced && matched.tempoRate != nil,
      "compatible tempos select tempo-paced transition")
check(matched.duration > 0 && matched.duration <= 8, "tempo transition is bounded")

let mismatch = LocalMixMath.automaticPlan(
    outgoingBPM: 75, incomingBPM: 155, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: true
)
check(mismatch.strategy == .quickFade && mismatch.tempoRate == nil,
      "incompatible tempos fall back to short fade")

let unknown = LocalMixMath.automaticPlan(
    outgoingBPM: 0, incomingBPM: 0, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: true
)
check(unknown.strategy == .smoothFade && unknown.tempoRate == nil,
      "unknown tempos use safe smooth fade")

print("[LocalMix] PASS: two-deck transition math, gain curves, duration bounds and tempo fallback")
