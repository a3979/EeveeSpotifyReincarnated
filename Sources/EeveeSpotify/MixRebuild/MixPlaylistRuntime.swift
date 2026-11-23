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
    private static var regularPlayerProbeStatus = -100
    private static var regularPlayerProbeAttempts = 0
    private static var regularPlayerProbeTimer: Timer?

    // Spotify's normal playback service is active even when the Premium Mix
    // transition service never initializes. Observe verified ObjC methods
    // without creating players or issuing playback commands.
    static func activateRegularPlayerProbe() {
        let start = {
            guard regularPlayerProbeTimer == nil, regularPlayerProbeStatus == -100 else { return }
            let probe = Timer(timeInterval: 0.25, repeats: true) { timer in
                regularPlayerProbeAttempts += 1
                let result = Int(MixRebuildInstallRegularPlayerObserver())
                if result > 0 || regularPlayerProbeAttempts >= 240 {
                    regularPlayerProbeStatus = result
                    timer.invalidate()
                    regularPlayerProbeTimer = nil
                }
            }
            RunLoop.main.add(probe, forMode: .common)
            regularPlayerProbeTimer = probe
            probe.fire()
        }
        if Thread.isMainThread { start() }
        else { DispatchQueue.main.async(execute: start) }
    }


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
    private static var bpmEstimate = MixRebuildTempo.unknown
    private static var bpmEnvelopeSamples = 0
    private static var bpmEnvelopeHz = 0.0
    private static var bpmFailureReason = "No active PCM sampling yet"
    private static var bpmRefreshTicks = 0

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
            MixRebuildSetDiagnosticsEnabled(true)
            let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
                let native = Int(MixRebuildActiveNativePCMPaths())
                let av = Int(MixRebuildActiveAVFoundationPCMPaths())
                peakNativePCMPaths = max(peakNativePCMPaths, native)
                peakAVPCMPaths = max(peakAVPCMPaths, av)
                bpmRefreshTicks += 1
                if bpmRefreshTicks % 5 == 0 { refreshPCMTempo() }
            }
            RunLoop.main.add(timer, forMode: .common)
            monitorTimer = timer
        }
    }

    private static func refreshPCMTempo() {
        var envelope = [Double](repeating: 0.0, count: 900)
        var count: UInt32 = 0
        var sampleHz = 0.0
        envelope.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            MixRebuildReadPCMEnvelope(base, UInt32(buffer.count), &count, &sampleHz)
        }
        bpmEnvelopeSamples = Int(count)
        bpmEnvelopeHz = sampleHz
        let samples = Array(envelope.prefix(Int(count)))
        bpmFailureReason = MixRebuildCore.tempoSignalDescription(energy: samples, envelopeHz: sampleHz)
        guard sampleHz.isFinite, (15...200).contains(sampleHz),
              Int(count) >= Int(sampleHz * 6) else {
            bpmEstimate = .unknown
            return
        }
        bpmEstimate = MixRebuildCore.estimateTempo(energy: samples, envelopeHz: sampleHz)
    }

    private static func stopPlaybackSampling() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        MixRebuildSetDiagnosticsEnabled(false)
        bpmRefreshTicks = 0
        bpmEstimate = .unknown
        bpmEnvelopeSamples = 0
        bpmEnvelopeHz = 0.0
        bpmFailureReason = "PCM monitor disabled"
    }


    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var seconds: Int {
        let v = UserDefaults.standard.integer(forKey: secondsKey)
        return (2...12).contains(v) ? v : 6
    }

    static var nativeStatus: String {
        enabled ? MixLocalPlayerBridge.shared.status : "Local Mix switch is OFF"
    }

    static func enable(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            // Install player-service observation only after the user explicitly
            // enables Local Mix. Keep it out of Spotify's launch path.
            activateRegularPlayerProbe()
            activatePlaybackVerification()
            peakNativePCMPaths = 0
            peakAVPCMPaths = 0
            startPlaybackSampling()
            MixLocalPlayerBridge.shared.setPreferredSeconds(seconds)
            MixLocalPlayerBridge.shared.enable()
        } else {
            MixLocalPlayerBridge.shared.disable()
            stopPlaybackSampling()
        }
        NotificationCenter.default.post(name: .mixPlaylistStateChanged, object: nil)
    }

    static func setSeconds(_ value: Int) {
        UserDefaults.standard.set(max(2, min(12, value)), forKey: secondsKey)
        MixLocalPlayerBridge.shared.setPreferredSeconds(seconds)
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

    // Native Spotify crossfade preferences are deliberately not written here.
    // Local Mix controls a second player and applies per-deck PCM gain instead.
    private static func apply() {
        requestedMilliseconds = enabled ? MixRebuildCore.crossfadeMilliseconds(seconds: seconds) : -1
        MixLocalPlayerBridge.shared.setPreferredSeconds(seconds)
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
            "Crossfade preference hook group attached: \(EeveeCrossfadeLateInstaller.activated)",
            "Crossfade preference class discovery attempts: \(EeveeCrossfadeLateInstaller.attempts)",
            "Preference lifecycle observations: \(preferenceLifecycleDetections)",
            "Preference class present: \(NSClassFromString("_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation") != nil)",
            "Crossfade capability flags registered: \(EeveeCrossfade.flags.keys.allSatisfy { RemoteFlags.shared.forced[$0] != nil })",
            "Original crossfade toggle known: \(originalEnabledKnown)",
            "Native reads: \(nativeReadCount)",
            "Native requested milliseconds: \(requestedMilliseconds)",
            "Native readback milliseconds: \(observedMilliseconds)",
            "PCM diagnostics active: \(enabled)",
            "PCM BPM estimate: \(bpmEstimate.confidence >= 0.28 ? "\(Int(bpmEstimate.bpm.rounded())) BPM" : "unavailable")",
            "PCM BPM confidence: \(String(format: "%.2f", bpmEstimate.confidence))",
            "PCM envelope: \(bpmEnvelopeSamples) samples at \(String(format: "%.1f", bpmEnvelopeHz)) Hz",
            "PCM tempo diagnostic: \(bpmFailureReason)",
            "BPM is estimated from observed PCM energy, not Spotify's track metadata.",
            "Playback overlap: NOT PROVEN (native timing does not establish concurrent tracks)",
            "Read-only monitor installation result: \(monitorStatus)",
            "Peak native PCM source paths in same 350ms window: \(peakNativePCMPaths)",
            "Peak AVFoundation PCM source paths in same 350ms window: \(peakAVPCMPaths)",
            "IMPORTANT: two audio paths may be one song routed through two units; distinct songs NOT proven.",
            "Current PCM probe: \(MixRebuildPlaybackMonitorStatus())",
            "Regular Spotify player service observer status: \(regularPlayerProbeStatus)",
            "Regular Spotify player service attachment attempts: \(regularPlayerProbeAttempts)",
            "Regular player service: \(MixRebuildRegularPlayerStatus())",
            "Local two-deck Mix engine: \(MixLocalPlayerBridge.shared.diagnostics)",
            "Native Spotify Mix pill intercepted: \(SpotifyNativeMixBinder.attached)",
            "Native Spotify Mix pill scans: \(SpotifyNativeMixBinder.scans)",
            "Native Spotify Mix pill bindings: \(SpotifyNativeMixBinder.binds)",
            "Native Spotify Mix tap callbacks: \(SpotifyNativeMixBinder.tapEvents)",
            "Native Spotify Mix long-press callbacks: \(SpotifyNativeMixBinder.longPressEvents)",
            "Last native Mix tap persisted state: \(SpotifyNativeMixBinder.lastTapEnabled.map(String.init(describing:)) ?? "not tapped yet")",
            "Native Mix pill green tint indicates UI switch state only; playback is not verified.",
            "Native player service hook installed: \(MixNativeServiceProbe.hookInstalled)",
            "Native player service discovery attempts: \(MixNativeServiceProbe.discoveryAttempts)",
            "Native player dependency injection callbacks: \(MixNativeServiceProbe.injections)",
            "Native player service observed: \(MixNativeServiceProbe.observed)",
            "Native transition-player service only exposes dependency injection/init; Spotify's other player-service APIs are listed below.",
            "Native Spotify mix components:"
        ] + found + ["Native ObjC player/UI method signatures:", MixRebuildDescribeNativeMixClasses()]).joined(separator: "\n")
    }
}
