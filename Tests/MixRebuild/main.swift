// CI build trigger: package the current embedded Mix implementation.
import Foundation

func assertMix(_ test: @autoclosure () -> Bool, _ why: String) {
    guard test() else {
        fputs("[MixRebuild] FAILED: \(why)\n", stderr)
        exit(1)
    }
}
func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.025) -> Bool {
    abs(a - b) <= tolerance
}
func pulses(bpm: Double, seconds: Double = 18, hz: Double = 50) -> [Double] {
    let count = Int(seconds * hz)
    let beatLength = hz * 60 / bpm
    return (0..<count).map { sample in
        let phase = Double(sample).truncatingRemainder(dividingBy: beatLength)
        return phase < 1.5 ? 0.95 : 0.015
    }
}
assertMix(MixRebuildCore.crossfadeMilliseconds(seconds: 8) == 8000,
          "8 seconds must be sent to Spotify as 8000 milliseconds")
assertMix(MixRebuildCore.crossfadeMilliseconds(seconds: 6) == 6000,
          "6 seconds must be sent to Spotify as 6000 milliseconds")
assertMix(MixRebuildCore.crossfadeMilliseconds(seconds: 12) == 12000,
          "12 seconds must be sent to Spotify as 12000 milliseconds")

assertMix(MixRebuildCore.tempoSignalDescription(
    energy: pulses(bpm: 120), envelopeHz: 50
).contains("beat periodicity detected"), "synthetic rhythm should explain detected beats")
assertMix(MixRebuildCore.tempoSignalDescription(
    energy: [Double](repeating: 0, count: 900), envelopeHz: 50
).contains("too quiet"), "silence should report silence, not a missing mixer")
func beatGrid(_ bpm: Double, duration: Double = 180, beatsPerBar: Int = 4) -> MixRebuildBeatGrid {
    let interval = 60.0 / bpm
    let count = Int(duration / interval)
    let beats = (0..<count).map { i in
        MixRebuildBeat(time: Double(i) * interval,
                      duration: interval,
                      beatInBar: i % beatsPerBar,
                      beatConfidence: 0.95,
                      downbeatConfidence: i % beatsPerBar == 0 ? 0.95 : 0.1)
    }
    return MixRebuildBeatGrid(beats: beats, beatsPerBar: beatsPerBar,
                              bpm: bpm, confidence: 0.95)
}
let overlap = MixRebuildCore.planOverlap(
    outgoing: beatGrid(120), incoming: beatGrid(124),
    outgoingDurationMs: 180_000, preferredSeconds: 8
)
assertMix(overlap.isBeatmatched, "compatible native beat grids should align")
assertMix(overlap.durationBars == 4 && overlap.durationMs == 8_000,
          "8 seconds at 120 BPM should use four 4/4 bars")
assertMix(near(Double(overlap.inSpeed), 120.0 / 124.0),
          "incoming deck speed should match the outgoing BPM")
assertMix(overlap.inStartPositionMs >= 1_000,
          "incoming deck should start on an actual downbeat after its intro")
assertMix(overlap.outStartPositionMs + overlap.durationMs <= 180_000,
          "outgoing fade must never extend beyond the outgoing track") 
let shiftedOutGrid = MixRebuildBeatGrid(
    beats: beatGrid(120).beats.map {
        MixRebuildBeat(time: $0.time + 0.25, duration: $0.duration,
                       beatInBar: $0.beatInBar, beatConfidence: $0.beatConfidence,
                       downbeatConfidence: $0.downbeatConfidence)
    },
    beatsPerBar: 4, bpm: 120, confidence: 0.95
)
let shortenedOverlap = MixRebuildCore.planOverlap(
    outgoing: shiftedOutGrid, incoming: beatGrid(124),
    outgoingDurationMs: 180_000, preferredSeconds: 8
)
assertMix(shortenedOverlap.isBeatmatched &&
          shortenedOverlap.outStartPositionMs + shortenedOverlap.durationMs <= 180_000,
          "late downbeat must shorten the overlap rather than overrun the source track")
let mismatchOverlap = MixRebuildCore.planOverlap(
    outgoing: beatGrid(75), incoming: beatGrid(155),
    outgoingDurationMs: 180_000, preferredSeconds: 8
)
assertMix(!mismatchOverlap.isBeatmatched && mismatchOverlap.inSpeed == 1,
          "large tempo mismatch must fall back instead of extreme time-stretching")
let fallbackOverlap = MixRebuildCore.planOverlap(
    outgoing: nil, incoming: nil, outgoingDurationMs: 180_000, preferredSeconds: 8
)
assertMix(!fallbackOverlap.isBeatmatched && fallbackOverlap.durationMs == 8_000,
          "missing beat metadata should still provide a safe smooth fade")

let a = MixRebuildCore.estimateTempo(energy: pulses(bpm: 120), envelopeHz: 50)
assertMix(near(a.bpm, 120, 0.6), "detect 120 BPM synthetic beat train: \(a)")
assertMix(a.confidence >= 0.28, "synthetic beat train has usable confidence")
let b = MixRebuildCore.estimateTempo(energy: pulses(bpm: 100), envelopeHz: 50)
assertMix(near(b.bpm, 100, 1), "detect 100 BPM: \(b)")
let quiet = MixRebuildCore.estimateTempo(
    energy: pulses(bpm: 120).map { $0 * 0.002 },
    envelopeHz: 50
)
assertMix(near(quiet.bpm, 120, 0.6),
          "quiet PCM must retain tempo after energy normalization: \(quiet)")
let nearSilence = MixRebuildCore.estimateTempo(
    energy: pulses(bpm: 120).map { $0 * 0.00001 },
    envelopeHz: 50
)
assertMix(nearSilence == .unknown,
          "near-silent PCM must not invent a confident BPM")
let silence = MixRebuildCore.estimateTempo(energy: Array(repeating: 0.0, count: 1000), envelopeHz: 50)
assertMix(silence == .unknown, "silence must not produce a BPM")
let constant = MixRebuildCore.estimateTempo(energy: Array(repeating: 0.7, count: 1000), envelopeHz: 50)
assertMix(constant == .unknown, "constant energy must not produce a BPM")

let matched = MixRebuildCore.plan(
    outgoing: MixRebuildTempo(bpm: 120, confidence: 0.8),
    incoming: MixRebuildTempo(bpm: 124, confidence: 0.75),
    preferredSeconds: 8, availableSeconds: 20)
assertMix(matched.style == .tempoPaced, "compatible beats plan tempo-paced overlap")
assertMix(near(matched.seconds, 4), "8 outgoing beats at 120 BPM is 4 seconds")
assertMix(near(Double(matched.incomingRate), 120.0 / 124.0), "tempo rate matches correctly")
let mismatched = MixRebuildCore.plan(
    outgoing: MixRebuildTempo(bpm: 75, confidence: 0.9),
    incoming: MixRebuildTempo(bpm: 155, confidence: 0.9),
    preferredSeconds: 8, availableSeconds: 20)
assertMix(mismatched.style == .quick && mismatched.incomingRate == 1,
          "different tempos must not pretend to sync")
assertMix(near(mismatched.seconds, 1.75), "severe mismatch uses quick blend")
let short = MixRebuildCore.plan(
    outgoing: a, incoming: b, preferredSeconds: 8, availableSeconds: 0.75)
assertMix(short.seconds <= 0.75, "do not fade beyond remaining track")
let unknown = MixRebuildCore.plan(
    outgoing: .unknown, incoming: .unknown, preferredSeconds: 8, availableSeconds: 20)
assertMix(unknown.style == .smooth && unknown.incomingRate == 1, "unknown beats fall back to smooth fade")

let beginning = MixRebuildCore.gains(progress: 0)
let middle = MixRebuildCore.gains(progress: 0.5)
let end = MixRebuildCore.gains(progress: 1)
assertMix(beginning.outgoing == 1 && beginning.incoming == 0, "outgoing-only start")
assertMix(end.outgoing < 0.00001 && end.incoming == 1, "incoming-only end")
assertMix(near(Double(middle.outgoing * middle.outgoing + middle.incoming * middle.incoming), 1, 0.00001),
          "equal-power envelope maintains sum of squared gains")
let sourceA = sin(2 * Double.pi * 440 * 0.011)
let sourceB = sin(2 * Double.pi * 660 * 0.011)
let mixed = Double(middle.outgoing) * sourceA + Double(middle.incoming) * sourceB
assertMix(abs(Double(middle.outgoing) * sourceA) > 0.01 &&
          abs(Double(middle.incoming) * sourceB) > 0.01 && mixed.isFinite,
          "two independent PCM sources contribute during a real blend")
print("[MixRebuild] PASS: tempo detection, honest compatibility, bounded plans and synthetic two-source mixing")
