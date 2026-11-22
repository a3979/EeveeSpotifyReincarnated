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
