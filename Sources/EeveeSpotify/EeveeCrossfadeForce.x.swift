import Foundation
import Orion
import EeveeSpotifyC

// Optional client-only transition prototype. A muted/fallback build must
// continue to use Spotify's normal audio processing.
enum LocalMixRuntime {
    private static weak var preferences: NSObject?
    private static var requestedSeconds = 0
    private static var appliedSeconds = -1
    private static var applyingInternally = false
    private static var ticker: Timer?
    private static let enabledKey = "eeveeLocalBeatMixEnabled"
    private static let beatsKey = "eeveeLocalBeatMixBeats"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var beats: Int {
        let v = UserDefaults.standard.integer(forKey: beatsKey)
        return [4, 8, 16].contains(v) ? v : 8
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        EeveeLocalMixSetEnabled(enabled)
        if enabled { tick() }
    }

    static func setBeats(_ beats: Int) {
        guard [4, 8, 16].contains(beats) else { return }
        UserDefaults.standard.set(beats, forKey: beatsKey)
        tick()
    }

    static func activate() {
        EeveeLocalMixSetEnabled(enabled)
        DispatchQueue.main.async {
            guard ticker == nil else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in tick() }
        }
        eeveeLog("[LocalBeatMix] Ready; enabled=%@", enabled ? "YES" : "NO")
    }

    // Hook intercepts the user's native crossfade slider. Zero remains zero.
    static func replacement(for value: Int) -> Int {
        if applyingInternally { return value }
        return Int(EeveeLocalMixSuggestCrossfadeSeconds(Int32(clamping: value), Int32(beats)))
    }

    static func remember(_ target: NSObject, requested: Int, applied: Int) {
        let wasInternal = applyingInternally
        let work = {
            preferences = target
            appliedSeconds = applied
            if !wasInternal { requestedSeconds = requested }
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    static func tick() {
        guard Thread.isMainThread, enabled, requestedSeconds > 0, let preferences else { return }
        guard EeveeLocalMixEstimatedBPM() > 0 else { return }
        let next = Int(EeveeLocalMixSuggestCrossfadeSeconds(
            Int32(clamping: requestedSeconds), Int32(beats)))
        guard next > 0 && abs(next - appliedSeconds) >= 2 else { return }
        applyingInternally = true
        EeveeLocalMixSetNativeCrossfadeTime(preferences, next)
        applyingInternally = false
        appliedSeconds = next
    }
}

struct EeveeCrossfadePrefGroup: HookGroup {}

class PreferencesCrossfadeHook: ClassHook<NSObject> {
    typealias Group = EeveeCrossfadePrefGroup
    static let targetName = "_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation"

    func setAudioCrossfadeTime(_ value: Int) {
        let adjusted = LocalMixRuntime.replacement(for: value)
        orig.setAudioCrossfadeTime(adjusted)
        orig.setAudioCrossfade(adjusted > 0)
        LocalMixRuntime.remember(target, requested: value, applied: adjusted)
    }

    func setAudioCrossfade(_ value: Bool) {
        orig.setAudioCrossfade(value)
    }
}

enum EeveeCrossfade {
    static let replacements = [
        EeveePropertyReplacement(name: "crossfade_enabled", scope: "ios-feature-settings", modification: .forceBool(true)),
        EeveePropertyReplacement(name: "crossfade_enabled", scope: "core-playback-setup", modification: .forceBool(true)),
        EeveePropertyReplacement(name: "use_playback_settings_crossfade", scope: "ios-feature-settings", modification: .forceBool(false)),
        EeveePropertyReplacement(name: "use_playback_settings_crossfade", scope: "playback-settings", modification: .forceBool(false)),
    ]
}

func activateEeveeCrossfadeForce() {
    guard NSClassFromString(PreferencesCrossfadeHook.targetName) != nil else {
        eeveeLog("[EeveeSpotify][Crossfade] Skipped: %@ missing", PreferencesCrossfadeHook.targetName)
        return
    }
    EeveeCrossfadePrefGroup().activate()
}
