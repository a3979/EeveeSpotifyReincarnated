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
    private static var applying = false
    private static var requestedMilliseconds = -1
    private static var observedMilliseconds = -1
    private static var nativeReadCount = 0

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
        }
        nativeReadCount += 1
        observedMilliseconds = milliseconds > 60 ? milliseconds : max(0, milliseconds) * 1000
        if !capturedOriginal && !applying {
            originalMilliseconds = observedMilliseconds
            if let enabled { originalEnabled = enabled }
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
        if !capturedOriginal && !applying { originalEnabled = value }
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
        let ms = enabled ? seconds * 1000 : (capturedOriginal ? originalMilliseconds : 0)
        let bool = enabled || (capturedOriginal && originalEnabled)
        applying = true
        MixRebuildSetNativeCrossfadeTime(preferences, ms)
        MixRebuildSetNativeCrossfadeEnabled(preferences, bool)
        applying = false
        requestedMilliseconds = enabled ? ms : -1
    }

    static func diagnostics() -> String {
        let native = [
            "PlaylistMixing_ElementKit.MixButtonElement",
            "PlaylistMixing_TransitionPlayerImpl.MixingTransitionPlayerImpl",
            "PlaylistMixing_MixingUIImpl.MixingEditViewController",
            "MixingTransitionPlayerServiceImpl"
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
            "Native reads: \(nativeReadCount)",
            "Native requested milliseconds: \(requestedMilliseconds)",
            "Native readback milliseconds: \(observedMilliseconds)",
            "Playback overlap: NOT MEASURED",
            "Native Spotify mix components:"
        ] + found).joined(separator: "\n")
    }
}
