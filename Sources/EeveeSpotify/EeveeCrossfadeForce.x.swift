import Foundation
import Orion

// The fade engine reads crossfade-enable from the persisted prefs; the duration
// slider writes setAudioCrossfadeTime: but never flips audioCrossfade, so it
// stays disabled (gapless). Keep the enable bool in sync with the duration.

struct EeveeCrossfadePrefGroup: HookGroup {}

class PreferencesCrossfadeHook: ClassHook<NSObject> {
    typealias Group = EeveeCrossfadePrefGroup
    static let targetName = "_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation"

    func audioCrossfadeTime() -> Int {
        let raw = orig.audioCrossfadeTime()
        let source = target
        if Thread.isMainThread {
            MixPlaylistRuntime.observe(source, milliseconds: raw)
        } else {
            DispatchQueue.main.async { MixPlaylistRuntime.observe(source, milliseconds: raw) }
        }
        return raw
    }

    func audioCrossfade() -> Bool {
        let value = orig.audioCrossfade()
        let source = target
        if Thread.isMainThread {
            MixPlaylistRuntime.observedSwitch(source, value: value)
        } else {
            DispatchQueue.main.async { MixPlaylistRuntime.observedSwitch(source, value: value) }
        }
        return value || MixPlaylistRuntime.enabled
    }

    func setAudioCrossfadeTime(_ value: Int) {
        orig.setAudioCrossfadeTime(value)
        guard !MixPlaylistRuntime.beginNativeSetter() else { return }
        // Spotify's duration slider otherwise fails to arm the native fade.
        orig.setAudioCrossfade(value > 0 || MixPlaylistRuntime.enabled)
        let source = target
        if Thread.isMainThread {
            MixPlaylistRuntime.observedNativeSetter(source, value: value)
        } else {
            DispatchQueue.main.async { MixPlaylistRuntime.observedNativeSetter(source, value: value) }
        }
    }

    func setAudioCrossfade(_ value: Bool) {
        orig.setAudioCrossfade(value || MixPlaylistRuntime.enabled)
    }
}

enum EeveeCrossfade {
    // These are *capability* flags, not proof that the Spotify Free playback
    // pipeline creates an incoming deck. Register them before RemoteFlags.prepare.
    static let flags: [String: Any] = [
        "ios-feature-settings.crossfade_enabled": true,
        "core-playback-setup.crossfade_enabled": true,
        "ios-feature-settings.use_playback_settings_crossfade": false,
        "playback-settings.use_playback_settings_crossfade": false
    ]

    // forced in 9.2's remote configuration (rewriteRemoteConfigurationData), where a Spotify experiment now
    // turns crossfade off: the settings row, the core's own gate, and both sides reading crossfade from the
    // local prefs the hook above keeps in step, rather than the server's playback settings.
    static let replacements = [
        EeveePropertyReplacement(name: "crossfade_enabled", scope: "ios-feature-settings", modification: .forceBool(true)),
        EeveePropertyReplacement(name: "crossfade_enabled", scope: "core-playback-setup", modification: .forceBool(true)),
        EeveePropertyReplacement(name: "use_playback_settings_crossfade", scope: "ios-feature-settings", modification: .forceBool(false)),
        EeveePropertyReplacement(name: "use_playback_settings_crossfade", scope: "playback-settings", modification: .forceBool(false)),
    ]
}

func activateEeveeCrossfadeForce() {
    RemoteFlags.shared.force(EeveeCrossfade.flags, by: "PlaylistMixCrossfade")
    guard NSClassFromString(PreferencesCrossfadeHook.targetName) != nil else {
        eeveeLog("[EeveeSpotify][Crossfade] Skipped: \(PreferencesCrossfadeHook.targetName) not found")
        return
    }
    EeveeCrossfadePrefGroup().activate()
}
