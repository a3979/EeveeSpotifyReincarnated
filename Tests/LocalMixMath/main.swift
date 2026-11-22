import Foundation

@inline(__always) func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("[LocalMixMath] FAIL: \(message)\n", stderr)
        exit(1)
    }
}
@inline(__always) func close(_ a: Double, _ b: Double, tolerance: Double = 0.000001) -> Bool {
    abs(a - b) <= tolerance
}

let linearStart = LocalMixMath.gains(curve: "Linear", progress: 0)
let linearMiddle = LocalMixMath.gains(curve: "Linear", progress: 0.5)
let linearEnd = LocalMixMath.gains(curve: "Linear", progress: 1)
expect(linearStart == LocalMixGainPair(outgoing: 1, incoming: 0), "linear start")
expect(linearMiddle == LocalMixGainPair(outgoing: 0.5, incoming: 0.5), "linear midpoint")
expect(linearEnd == LocalMixGainPair(outgoing: 0, incoming: 1), "linear end")

let equal = LocalMixMath.gains(curve: "Equal power", progress: 0.5)
expect(abs(equal.outgoing * equal.outgoing + equal.incoming * equal.incoming - 1) < 0.000001,
       "equal-power midpoint preserves squared gain")
let smoothStart = LocalMixMath.gains(curve: "S-curve", progress: 0)
let smoothEnd = LocalMixMath.gains(curve: "S-curve", progress: 1)
expect(close(smoothStart.outgoing, 1) && close(smoothStart.incoming, 0), "S-curve start")
expect(close(smoothEnd.outgoing, 0) && close(smoothEnd.incoming, 1), "S-curve end")
expect(LocalMixMath.gains(curve: "Hard cut", progress: 0.49) == LocalMixGainPair(outgoing: 1, incoming: 0),
       "hard cut before midpoint")
expect(LocalMixMath.gains(curve: "Hard cut", progress: 0.5) == LocalMixGainPair(outgoing: 0, incoming: 1),
       "hard cut at midpoint")
let clamped = LocalMixMath.gains(curve: "Equal power", progress: 4)
expect(close(clamped.outgoing, 0) && close(clamped.incoming, 1), "progress is clamped")
expect(LocalMixMath.transitionDuration(requested: 8, remaining: 12, outroTrim: 2) == 8,
       "requested transition duration retained")
expect(LocalMixMath.transitionDuration(requested: 8, remaining: 5, outroTrim: 2) == 3,
       "transition clamped to usable outro")
expect(LocalMixMath.transitionDuration(requested: 8, remaining: 0.1, outroTrim: 0) == 0.25,
       "minimum handoff duration")
expect(LocalMixMath.tempoRate(outgoingBPM: 120, incomingBPM: 120) == 1,
       "tempo match unity")
expect(LocalMixMath.tempoRate(outgoingBPM: 132, incomingBPM: 120) == 1.1,
       "tempo match upper bound")
expect(LocalMixMath.tempoRate(outgoingBPM: 60, incomingBPM: 120) == nil,
       "reject unusable tempo")

print("[LocalMixMath] PASS: transition curves, duration bounds, and tempo limits")


expect(LocalMixCrossfadeMath.normalizeMilliseconds(8) == 8000,
       "legacy seconds must be normalized to native milliseconds")
expect(LocalMixCrossfadeMath.normalizeMilliseconds(8000) == 8000,
       "native millisecond value must not be double-converted")
expect(LocalMixCrossfadeMath.normalizeMilliseconds(0) == 0,
       "zero preserves original crossfade off")
expect(LocalMixCrossfadeMath.requestedMilliseconds(baseSeconds: 8, bpm: 120, beats: 8) == 4000,
       "8 beats at 120 BPM sends 4000 milliseconds, never 4 milliseconds")
expect(LocalMixCrossfadeMath.requestedMilliseconds(baseSeconds: 8, bpm: 120, beats: 16) == 8000,
       "16 beats at 120 BPM sends 8000 milliseconds")
expect(LocalMixCrossfadeMath.requestedMilliseconds(baseSeconds: 0, bpm: 0, beats: 8) == 8000,
       "unavailable BPM arms a safe 8-second crossfade")
expect(LocalMixCrossfadeMath.requestedMilliseconds(baseSeconds: 8, bpm: 75, beats: 16) == 12000,
       "max beat length capped at 12 seconds")
print("[LocalMixMath] PASS: native millisecond conversion and beat-timing units")


// The local-file player has two separately decoded AVAudioPlayerNodes. These
// deterministic tests validate the gain and scheduling math; they cannot
// establish whether Spotify Free exposes two streaming playback decks.
let closeTempo = LocalMixMath.automaticPlan(
    outgoingBPM: 120, incomingBPM: 124, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: true)
expect(closeTempo.strategy == .tempoPaced, "nearby tempos use tempo-paced overlap")
expect(close(closeTempo.duration, 4), "120 BPM outgoing uses an eight-beat fade")
expect(closeTempo.tempoRate != nil, "nearby tempos have a bounded playback-rate adjustment")

let mediumMismatch = LocalMixMath.automaticPlan(
    outgoingBPM: 120, incomingBPM: 150, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: true)
expect(mediumMismatch.strategy == .smoothFade && mediumMismatch.tempoRate == nil,
       "different tempos use ordinary fade without pretending to sync")
expect(close(mediumMismatch.duration, 4), "different tempos use a 4-second fade")

let severeMismatch = LocalMixMath.automaticPlan(
    outgoingBPM: 70, incomingBPM: 180, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: true)
expect(severeMismatch.strategy == .quickFade && severeMismatch.tempoRate == nil,
       "widely separated tempos use a short handoff")
expect(close(severeMismatch.duration, 2), "quick handoff is limited to 2 seconds")

let unknownTempo = LocalMixMath.automaticPlan(
    outgoingBPM: 0, incomingBPM: 0, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: true)
expect(unknownTempo.strategy == .smoothFade && unknownTempo.tempoRate == nil,
       "unknown BPM never claims synchronization")
expect(close(unknownTempo.duration, 6), "unknown BPM uses gentle fallback")

let noSync = LocalMixMath.automaticPlan(
    outgoingBPM: 120, incomingBPM: 121, requestedSeconds: 8,
    remaining: 20, outroTrim: 0, syncTempo: false)
expect(noSync.tempoRate == nil && noSync.strategy == .smoothFade,
       "disabled tempo sync never alters playback rate")

let shortOutro = LocalMixMath.automaticPlan(
    outgoingBPM: 120, incomingBPM: 120, requestedSeconds: 8,
    remaining: 2.3, outroTrim: 0.8, syncTempo: true)
expect(close(shortOutro.duration, 1.5), "adaptive fade fits remaining track audio")
expect(LocalMixMath.tempoRate(outgoingBPM: 70, incomingBPM: 180) == nil,
       "large tempo mismatch must never clamp and pretend to match")

// Two independent synthetic input signals should overlap audibly during the
// equal-power transition instead of merely animating the Mix UI.
let left = sin(2 * Double.pi * 440.0 * 0.011)
let right = sin(2 * Double.pi * 660.0 * 0.011)
let atMid = LocalMixMath.gains(curve: "Equal power", progress: 0.5)
let mixedSample = left * atMid.outgoing + right * atMid.incoming
expect(abs(left * atMid.outgoing) > 0.01 && abs(right * atMid.incoming) > 0.01,
       "both local-file decks contribute to the midpoint")
expect(mixedSample.isFinite, "mixed synthetic sample is finite")

print("[LocalMixMath] PASS: adaptive plans, honest tempo sync, and synthetic dual-deck overlap")
