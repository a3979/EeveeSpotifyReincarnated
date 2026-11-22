import Foundation
import Orion
import EeveeSpotifyC

// Client-only transition probe. Spotify's current Free service may still
// disable audible crossfade even when preferences and analysis are functional.
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
    private static var capturedUserValue = false
    private static var nativeReads = 0
    private static var nativeWrites = 0
    private static var lastReadSeconds = -1
    private static var postRequestReadback: Int?

    static var nativeRequestStatus: String {
        guard preferences != nil else { return "Waiting for Spotify preferences" }
        let requested = appliedSeconds >= 0 ? String(format: "%.1fs (%dms)", Double(appliedSeconds) / 1000, appliedSeconds) : "Not requested"
        return "Requested \(requested) · reads \(nativeReads) · setter calls \(nativeWrites)"
    }
    static var nativeReadbackStatus: String {
        guard appliedSeconds >= 0 else { return "No duration requested" }
        guard let observed = postRequestReadback else { return "No Spotify read since request" }
        return observed == appliedSeconds
            ? "Preference matches request (audio unverified)"
            : "Preference differs: \(observed)ms"
    }
    static var diagnosticSnapshot: String {
        // No song titles, account identifiers or raw PCM are included.
        let probe = EeveeLocalMixProbeState()
        let status = probe == 2 ? "Receiving PCM" : probe == 1 ? "Waiting for PCM" : "Unavailable"
        return [
            "EeveeSpotify Local Beat Mix · diagnostic v2",
            "iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Enabled: \(enabled)",
            "Transition beats: \(beats)",
            "Probe: \(status)",
            "Estimated tempo: \(EeveeLocalMixEstimatedBPM()) BPM",
            "Spotify preference object seen: \(preferences != nil)",
            "Native duration requested (ms): \(appliedSeconds)",
            "Native preference readback: \(nativeReadbackStatus)",
            "Native getter calls: \(nativeReads)",
            "Native setter calls: \(nativeWrites)",
            "Last native getter value (raw): \(lastReadSeconds)",
            "Saved original crossfade: \(savedCrossfadeStatus)",
            "Important: native settings and PCM sampling do not prove two tracks overlap."
        ].joined(separator: "\n")
    }
    static var savedCrossfadeStatus: String {
        capturedUserValue ? "\(requestedSeconds)s" : "Not yet observed"
    }
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
            if capturedUserValue { apply(requestedSeconds) }
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
        let probeStatus = EeveeLocalMixInstallAudioProbe()
        eeveeLog("[LocalBeatMix] PCM hook install status=%d", probeStatus)
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
        guard enabled else { return value }
        let originalMilliseconds = LocalMixCrossfadeMath.normalizeMilliseconds(value)
        let baseSeconds = originalMilliseconds / 1000
        return LocalMixCrossfadeMath.requestedMilliseconds(
            baseSeconds: baseSeconds, bpm: Int(EeveeLocalMixEstimatedBPM()), beats: beats)
    }

    // Spotify may never call the setter after launch. Its ObjC-visible
    // audioCrossfadeTime getter provides a second opportunity to capture
    // its preferences object and arm an actual millisecond-duration request.
    static func observedGetter(_ target: NSObject, value: Int) {
        let capture = {
            nativeReads += 1
            lastReadSeconds = value
            if preferences !== target {
                preferences = target
                appliedSeconds = -1
                postRequestReadback = nil
            }
            if appliedSeconds >= 0 && !applyingInternally {
                postRequestReadback = LocalMixCrossfadeMath.normalizeMilliseconds(value)
            }
            if !capturedUserValue && !applyingInternally && nativeWrites == 0 {
                requestedSeconds = LocalMixCrossfadeMath.normalizeMilliseconds(value) / 1000
                capturedUserValue = true
            }
            guard !applyingInternally, enabled else { return }
            if pendingApply {
                pendingApply = false
                apply(activeBaseSeconds)
            }
        }
        if Thread.isMainThread { capture() }
        else { DispatchQueue.main.async(execute: capture) }
    }

    // Some Spotify builds call only the enable/disable preference setter.
    // Capture that object too so the local toggle can arm a real duration,
    // even if the native crossfade slider is never opened.
    static func observeSwitch(_ target: NSObject) {
        let work = {
            if preferences !== target {
                preferences = target
                appliedSeconds = -1
            }
            if enabled && pendingApply && !applyingInternally {
                pendingApply = false
                apply(activeBaseSeconds)
            }
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    static func remember(_ target: NSObject, requested: Int, applied: Int) {
        let wasInternal = applyingInternally
        let work = {
            preferences = target
            appliedSeconds = applied
            nativeWrites += 1
            guard !wasInternal else { return }
            requestedSeconds = LocalMixCrossfadeMath.normalizeMilliseconds(requested) / 1000
            capturedUserValue = true
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
        let milliseconds: Int
        if enabled {
            milliseconds = LocalMixCrossfadeMath.requestedMilliseconds(
                baseSeconds: seconds, bpm: Int(EeveeLocalMixEstimatedBPM()), beats: beats)
        } else {
            milliseconds = max(0, seconds) * 1000
        }
        guard milliseconds != appliedSeconds else { return }
        postRequestReadback = nil
        applyingInternally = true
        EeveeLocalMixSetNativeCrossfadeTime(preferences, milliseconds)
        applyingInternally = false
        appliedSeconds = milliseconds
        eeveeLog("[LocalBeatMix] native crossfade request=%dms, estimated BPM=%d, enabled=%@",
                 milliseconds, EeveeLocalMixEstimatedBPM(), enabled ? "YES" : "NO")
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

    func audioCrossfadeTime() -> Int {
        let value = orig.audioCrossfadeTime()
        LocalMixRuntime.observedGetter(target, value: value)
        return value
    }

    func audioCrossfade() -> Bool {
        let value = orig.audioCrossfade()
        return value || LocalMixRuntime.enabled
    }

    func setAudioCrossfadeTime(_ value: Int) {
        let adjusted = LocalMixRuntime.replacement(for: value)
        orig.setAudioCrossfadeTime(adjusted)
        orig.setAudioCrossfade(adjusted > 0 || LocalMixRuntime.enabled)
        LocalMixRuntime.remember(target, requested: value, applied: adjusted)
    }

    func setAudioCrossfade(_ value: Bool) {
        // Our local mode keeps Spotify's normal crossfade armed while active.
        // This is independent of Spotify's Premium playlist Mix toggle.
        orig.setAudioCrossfade(value || LocalMixRuntime.enabled)
        LocalMixRuntime.observeSwitch(target)
    }
}

enum EeveeCrossfade {
    // Kept as property replacements for the v3 remote-configuration rewrite.
    static let replacements = [
        EeveePropertyReplacement(name: "crossfade_enabled", scope: "ios-feature-settings", modification: .forceBool(true)),
        EeveePropertyReplacement(name: "crossfade_enabled", scope: "core-playback-setup", modification: .forceBool(true)),
        EeveePropertyReplacement(name: "use_playback_settings_crossfade", scope: "ios-feature-settings", modification: .forceBool(false)),
        EeveePropertyReplacement(name: "use_playback_settings_crossfade", scope: "playback-settings", modification: .forceBool(false)),
    ]

    // Register these before RemoteFlags.prepare() so Spotify's native crossfade
    // remains available to the local mode. This does not enable cloud AutoMix.
    // AutoMix, server-side transitions or any Premium entitlement.
    static let flags: [String: Any] = [
        "ios-feature-settings.crossfade_enabled": true,
        "core-playback-setup.crossfade_enabled": true,
        "ios-feature-settings.use_playback_settings_crossfade": false,
        "playback-settings.use_playback_settings_crossfade": false,
    ]
}

func activateEeveeCrossfadeForce() {
    RemoteFlags.shared.force(EeveeCrossfade.flags, by: "LocalBeatMix")
    LocalMixRuntime.activate()
    guard NSClassFromString(PreferencesCrossfadeHook.targetName) != nil else {
        eeveeLog("[EeveeSpotify][Crossfade] Preferences hook target absent: %@", PreferencesCrossfadeHook.targetName)
        return
    }
    EeveeCrossfadePrefGroup().activate()
}
