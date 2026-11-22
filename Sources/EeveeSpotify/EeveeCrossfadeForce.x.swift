import Foundation
import Orion
import EeveeSpotifyC

// Optional client-only transition prototype. A muted/fallback build must
// continue to use Spotify's normal audio processing.
extension Notification.Name {
    static let eeveeLocalMixStateChanged = Notification.Name("EeveeLocalMixStateChanged")
}

// Local Beat Mix is a client-side mode layered over Spotify's existing playback
// crossfade. It does not invoke Spotify's cloud Mix service or unlock its editor.
enum LocalMixRuntime {
    private static weak var preferences: NSObject?
    // The user's saved crossfade value. This is restored when Local Beat Mix is
    // switched off, even if Mix temporarily uses the 8-second fallback.
    private static var requestedSeconds = 0
    private static var appliedSeconds = -1
    private static var applyingInternally = false
    private static var pendingApply = false
    private static var ticker: Timer?
    private static let defaultCrossfadeSeconds = 8
    private static let enabledKey = "eeveeLocalBeatMixEnabled"
    private static let beatsKey = "eeveeLocalBeatMixBeats"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var beats: Int {
        let value = UserDefaults.standard.integer(forKey: beatsKey)
        return [4, 8, 16].contains(value) ? value : 8
    }

    private static var activeBaseSeconds: Int {
        requestedSeconds > 0 ? requestedSeconds : defaultCrossfadeSeconds
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
        EeveeLocalMixSetEnabled(value)
        if value {
            if preferences != nil {
                pendingApply = false
                apply(activeBaseSeconds)
            } else {
                pendingApply = true
            }
        } else {
            pendingApply = false
            // Restore the user's actual Spotify crossfade setting, including zero.
            apply(requestedSeconds)
        }
        NotificationCenter.default.post(name: .eeveeLocalMixStateChanged, object: nil)
    }

    static func setBeats(_ value: Int) {
        guard [4, 8, 16].contains(value) else { return }
        UserDefaults.standard.set(value, forKey: beatsKey)
        tick()
        NotificationCenter.default.post(name: .eeveeLocalMixStateChanged, object: nil)
    }

    static func activate() {
        EeveeLocalMixSetEnabled(enabled)
        if enabled {
            pendingApply = preferences == nil
            if preferences != nil { apply(activeBaseSeconds) }
        }
        DispatchQueue.main.async {
            guard ticker == nil else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in tick() }
        }
        eeveeLog("[LocalBeatMix] Ready; enabled=%@", enabled ? "YES" : "NO")
    }

    // Intercept the user's native slider. While Mix is enabled, Spotify's
    // crossfade stays armed; a zero setting uses the local 8-second fallback.
    static func replacement(for value: Int) -> Int {
        if applyingInternally { return value }
        guard enabled, value > 0 else { return value }
        return Int(EeveeLocalMixSuggestCrossfadeSeconds(
            Int32(clamping: value), Int32(clamping: beats)))
    }

    static func remember(_ target: NSObject, requested: Int, applied: Int) {
        let wasInternal = applyingInternally
        let work = {
            preferences = target
            appliedSeconds = applied
            guard !wasInternal else { return }
            requestedSeconds = requested
            if enabled && (pendingApply || requested == 0) {
                pendingApply = false
                apply(activeBaseSeconds)
            }
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    private static func apply(_ seconds: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { apply(seconds) }
            return
        }
        guard let preferences else {
            pendingApply = enabled
            return
        }
        let next: Int
        if enabled && seconds > 0 {
            next = Int(EeveeLocalMixSuggestCrossfadeSeconds(
                Int32(clamping: seconds), Int32(clamping: beats)))
        } else {
            next = max(0, seconds)
        }
        guard next != appliedSeconds else { return }
        applyingInternally = true
        EeveeLocalMixSetNativeCrossfadeTime(preferences, next)
        applyingInternally = false
        appliedSeconds = next
    }

    static func tick() {
        guard Thread.isMainThread, enabled,
              EeveeLocalMixEstimatedBPM() > 0 else { return }
        apply(activeBaseSeconds)
    }
}

struct EeveeCrossfadePrefGroup: HookGroup {}

class PreferencesCrossfadeHook: ClassHook<NSObject> {
    typealias Group = EeveeCrossfadePrefGroup
    static let targetName = "_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation"

    func setAudioCrossfadeTime(_ value: Int) {
        let adjusted = LocalMixRuntime.replacement(for: value)
        orig.setAudioCrossfadeTime(adjusted)
        orig.setAudioCrossfade(adjusted > 0 || LocalMixRuntime.enabled)
        LocalMixRuntime.remember(target, requested: value, applied: adjusted)
    }

    func setAudioCrossfade(_ value: Bool) {
        // Mix owns the crossfade switch while active; users can disable it by
        // turning Local Beat Mix off first.
        orig.setAudioCrossfade(value || LocalMixRuntime.enabled)
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
