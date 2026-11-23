import Foundation

/// Spotify's ObjC preferences store crossfade duration in milliseconds.
/// Older/experimental hook callers sometimes pass slider seconds. Convert
/// either representation before writing to the native playback preferences.
enum LocalMixCrossfadeMath {
    static func normalizeMilliseconds(_ rawValue: Int) -> Int {
        guard rawValue > 0 else { return 0 }
        if rawValue <= 60 { return rawValue * 1000 }
        return min(rawValue, 60_000)
    }

    /// A positive fallback is required to arm crossfade while the original
    /// user setting is zero. Never mistake "8 beats" for "8 milliseconds".
    static func requestedMilliseconds(baseSeconds: Int, bpm: Int, beats: Int) -> Int {
        let fallback = min(12_000, max(1000, baseSeconds > 0 ? baseSeconds * 1000 : 8000))
        guard (60...220).contains(bpm), [4, 8, 16].contains(beats) else { return fallback }
        let barMilliseconds = (Double(beats) * 60_000.0 / Double(bpm)).rounded()
        return min(12_000, max(2000, Int(barMilliseconds)))
    }
}
