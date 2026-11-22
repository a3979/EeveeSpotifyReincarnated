import Foundation
import UIKit
import ObjectiveC.runtime
import EeveeSpotifyC

// Spotify streaming integration. This is deliberately separate from the
// imported-file AVAudioEngine: encrypted Spotify songs must NEVER be passed
// off as local audio files, and a preference write is not proof of a blend.
extension Notification.Name {
    static let mixPlaylistStateChanged = Notification.Name("EeveeMixPlaylistStateChanged")
}

enum MixPlaylistRuntime {
    private static let enabledKey = "eeveeMixPlaylistEnabled"
    private static let secondsKey = "eeveeMixPlaylistFadeSeconds"
    private static weak var preferences: NSObject?
    private static var capturedOriginal = false
    private static var originalMilliseconds = 0
    private static var originalEnabled = false
    private static var originalEnabledKnown = false
    private static var applying = false
    private static var requestedMilliseconds = -1
    private static var observedMilliseconds = -1
    private static var nativeReadCount = 0
    private static var preferenceCaptureMask = -100
    private static var preferencePollTimer: Timer?
    private static var preferenceLifecycleDetections = 0

    // Spotify Free may never call the public-shaped crossfade getters. Observe
    // only verified Objective-C init/injection methods of the *exact* class,
    // then query a live object with typed scalar selectors. No arbitrary
    // memory scanning, fake Premium permission response or audio modification.
    static func activatePreferenceCapture() {
        guard preferenceCaptureMask == -100 else { return }
        preferenceCaptureMask = Int(MixRebuildInstallPreferenceCapture())
        DispatchQueue.main.async {
            guard preferencePollTimer == nil else { return }
            let timer = Timer(timeInterval: 0.75, repeats: true) { _ in
                discoverPreferencesObject()
            }
            RunLoop.main.add(timer, forMode: .common)
            preferencePollTimer = timer
            discoverPreferencesObject()
        }
    }

    private static func discoverPreferencesObject() {
        guard Thread.isMainThread else { return }
        preferenceLifecycleDetections = Int(MixRebuildPreferenceCaptureEvents())
        guard preferences == nil,
              let object = MixRebuildObservedPreferenceObject() as? NSObject else { return }
        let raw = Int(MixRebuildReadNativeCrossfadeTimeOrNeg1(object))
        let switchValue = Int(MixRebuildReadNativeCrossfadeEnabledOrNeg1(object))
        if raw >= 0 {
            observe(object, milliseconds: raw, enabled: switchValue < 0 ? nil : switchValue != 0)
        } else {
            preferences = object
            if enabled { apply() }
        }
    }
    private static var monitorInstalled = false
    private static var monitorStatus = -100
    private static var monitorTimer: Timer?
    private static var peakNativePCMPaths = 0
    private static var peakAVPCMPaths = 0

    static func activatePlaybackVerification() {
        guard !monitorInstalled else { return }
        monitorInstalled = true
        monitorStatus = Int(MixRebuildInstallPlaybackProbe())
        if enabled { startPlaybackSampling() }
    }

    private static func startPlaybackSampling() {
        guard monitorTimer == nil else { return }
        DispatchQueue.main.async {
            guard enabled, monitorTimer == nil else { return }
            let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
                let native = Int(MixRebuildActiveNativePCMPaths())
                let av = Int(MixRebuildActiveAVFoundationPCMPaths())
                peakNativePCMPaths = max(peakNativePCMPaths, native)
                peakAVPCMPaths = max(peakAVPCMPaths, av)
            }
            RunLoop.main.add(timer, forMode: .common)
            monitorTimer = timer
        }
    }

    private static func stopPlaybackSampling() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }


    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var seconds: Int {
        let v = UserDefaults.standard.integer(forKey: secondsKey)
        return (2...12).contains(v) ? v : 6
    }

    static var nativeStatus: String {
        guard preferences != nil else { return "Waiting for Spotify playback preferences" }
        if !enabled { return "Local Mix is off" }
        if requestedMilliseconds < 0 { return "Waiting to request playback crossfade" }
        if observedMilliseconds == requestedMilliseconds {
            return "Crossfade setting accepted; audio overlap unverified"
        }
        return "Crossfade requested; audio overlap unverified"
    }

    static func enable(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { discoverPreferencesObject() }
        if on {
            peakNativePCMPaths = 0
            peakAVPCMPaths = 0
            startPlaybackSampling()
        } else {
            stopPlaybackSampling()
        }
        apply()
        NotificationCenter.default.post(name: .mixPlaylistStateChanged, object: nil)
    }

    static func setSeconds(_ value: Int) {
        UserDefaults.standard.set(max(2, min(12, value)), forKey: secondsKey)
        if enabled { apply() }
        NotificationCenter.default.post(name: .mixPlaylistStateChanged, object: nil)
    }

    // Getter and setter hooks are installed only if Spotify 9.2.2 exposes the
    // correct ObjC-visible native preference implementation.
    static func observe(_ object: NSObject, milliseconds: Int, enabled: Bool? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { observe(object, milliseconds: milliseconds, enabled: enabled) }
            return
        }
        if preferences !== object {
            preferences = object
            observedMilliseconds = -1
            requestedMilliseconds = -1
            capturedOriginal = false
            originalEnabledKnown = false
        }
        nativeReadCount += 1
        observedMilliseconds = milliseconds > 60 ? milliseconds : max(0, milliseconds) * 1000
        if !capturedOriginal && !applying {
            originalMilliseconds = observedMilliseconds
            if let enabled {
                originalEnabled = enabled
                originalEnabledKnown = true
            }
            capturedOriginal = true
        }
        if self.enabled && requestedMilliseconds < 0 && !applying {
            // No ObjC calls from the playback getter's stack.
            DispatchQueue.main.async {
                guard self.enabled else { return }
                self.apply()
            }
        }
    }

    static func observedSwitch(_ object: NSObject, value: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { observedSwitch(object, value: value) }
            return
        }
        if preferences == nil { preferences = object }
        if !applying && !originalEnabledKnown {
            originalEnabled = value
            originalEnabledKnown = true
        }
        // Some Spotify builds only ask whether crossfade is on, never calling
        // the duration getter. Still attach to the correct preference object.
        if enabled && requestedMilliseconds < 0 && !applying {
            DispatchQueue.main.async {
                if enabled && requestedMilliseconds < 0 { apply() }
            }
        }
    }

    static func beginNativeSetter() -> Bool { applying }
    static func observedNativeSetter(_ object: NSObject, value: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { observedNativeSetter(object, value: value) }
            return
        }
        preferences = object
        if !applying && !enabled {
            originalMilliseconds = value > 60 ? value : max(0, value) * 1000
            capturedOriginal = true
        }
    }

    private static func apply() {
        guard let preferences else { return }
        // Never replace an unknown original Spotify preference with zero.
        guard enabled || capturedOriginal else { return }
        let ms = enabled ? seconds * 1000 : originalMilliseconds
        let bool = enabled || originalEnabled
        applying = true
        MixRebuildSetNativeCrossfadeTime(preferences, ms)
        if enabled || originalEnabledKnown {
            MixRebuildSetNativeCrossfadeEnabled(preferences, bool)
        }
        applying = false
        requestedMilliseconds = enabled ? ms : -1
    }

    static func diagnostics() -> String {
        // Verified by inspecting Spotify 9.2.2's Mach-O Objective-C class
        // list, not guessed Swift module-qualified names. The player itself
        // exposes no public/ObjC startMix method.
        let native = [
            "_TtC35PlaylistMixing_TransitionPlayerImpl26MixingTransitionPlayerImpl",
            "_TtC35PlaylistMixing_TransitionPlayerImpl33MixingTransitionPlayerServiceImpl",
            "_TtC27PlaylistMixing_MixingUIImpl24MixingEditViewController",
            "_TtC31NowPlaying_MixingTransitionImpl27MixingTransitionServiceImpl",
            "_TtC25PlaylistMixing_ElementKit20MixingTransitionView"
        ]
        let found = native.map { name -> String in
            let available = NSClassFromString(name) != nil
            return "\(name): \(available ? "class present" : "not ObjC-visible")"
        }
        return ([
            "EeveeSpotify Mix · native integration diagnostics",
            "iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mix enabled: \(enabled)",
            "Requested crossfade: \(seconds)s",
            "Spotify preferences available: \(preferences != nil)",
            "Preference lifecycle hook mask (1=init,2=injection): \(preferenceCaptureMask)",
            "Preference lifecycle observations: \(preferenceLifecycleDetections)",
            "Preference class present: \(NSClassFromString("_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation") != nil)",
            "Crossfade capability flags registered: \(EeveeCrossfade.flags.keys.allSatisfy { RemoteFlags.shared.forced[$0] != nil })",
            "Original crossfade toggle known: \(originalEnabledKnown)",
            "Native reads: \(nativeReadCount)",
            "Native requested milliseconds: \(requestedMilliseconds)",
            "Native readback milliseconds: \(observedMilliseconds)",
            "Playback overlap: NOT PROVEN (native timing does not establish concurrent tracks)",
            "Read-only monitor installation result: \(monitorStatus)",
            "Peak native PCM source paths in same 350ms window: \(peakNativePCMPaths)",
            "Peak AVFoundation PCM source paths in same 350ms window: \(peakAVPCMPaths)",
            "IMPORTANT: two audio paths may be one song routed through two units; distinct songs NOT proven.",
            "Current PCM probe: \(MixRebuildPlaybackMonitorStatus())",
            "Native player dependency injection callbacks: \(MixNativeServiceProbe.injections)",
            "Native player service observed: \(MixNativeServiceProbe.observed)",
            "Native player service methods: ObjC exposes dependency injection and init only",
            "Native Spotify mix components:"
        ] + found + ["Native ObjC player/UI method signatures:", MixRebuildDescribeNativeMixClasses()]).joined(separator: "\n")
    }
}
