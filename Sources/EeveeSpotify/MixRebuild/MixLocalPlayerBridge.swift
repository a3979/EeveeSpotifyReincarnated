import Foundation
import EeveeSpotifyC

/// A local counterpart to Spotify's native transition-player topology.
/// It asks Spotify's ordinary player service for a second player, prepares
/// the next queued track, and only fades after a second independent PCM path
/// has actually appeared. If Spotify cannot supply that path, Deck A is untouched.
final class MixLocalPlayerBridge {
    static let shared = MixLocalPlayerBridge()

    private enum Phase: String {
        case off, waitingForPlayer, waitingForQueue, preparing, ready
        case waitingForSecondPCM, transitioning, promotionFallback, failed
    }

    private var timer: Timer?
    private var enabled = false
    private var phase: Phase = .off
    private var preferredSeconds = 6
    private var mainPlayer: NSObject?
    private var secondaryPlayer: NSObject?
    private var playerList: NSObject?
    private var currentQueue: NSObject?
    private var nextQueue: NSObject?
    private var incomingContext: NSObject?
    private var viewURI: AnyObject?
    private var incomingTrackURI: String?
    private var activeTrackURI: String?
    private var sourceIDsBefore = Set<UInt32>()
    private var registeredSourceIDsBefore = Set<UInt32>()
    private var outgoingSourceID: UInt32?
    private var incomingSourceID: UInt32?
    private var overlap: MixRebuildOverlap?
    private var playRequestedAt: Date?
    private var muteArmedAt: Date?
    private var lastProgress = 0.0
    private var lastError = ""
    private var ticks = 0
    private var lastPrepareAttemptAt: Date = .distantPast

    private init() {}

    var status: String {
        switch phase {
        case .off: return "Local Mix is OFF"
        case .waitingForPlayer: return "Local Mix is waiting for Spotify playback"
        case .waitingForQueue: return "Playing normally; waiting for a next queued track"
        case .preparing: return "Preparing the next track on a second Spotify player"
        case .ready: return "Next track prepared; waiting for the transition point"
        case .waitingForSecondPCM: return "Starting the incoming deck and verifying its audio path"
        case .transitioning: return "Local two-deck transition in progress"
        case .promotionFallback: return "Transition audio completed; player handoff needs attention"
        case .failed: return lastError.isEmpty ? "Local Mix could not start; current playback is unchanged" : lastError
        }
    }

    var diagnostics: String {
        let sources = activeSourceIDs().map(String.init).joined(separator: ",")
        let out = outgoingSourceID.map(String.init) ?? "none"
        let incoming = incomingSourceID.map(String.init) ?? "none"
        let progress = String(format: "%.0f%%", lastProgress * 100)
        return "phase=\(phase.rawValue); mainPlayer=\(mainPlayer != nil); secondPlayer=\(secondaryPlayer != nil); queue=\(currentQueue != nil); incomingTrack=\(incomingTrackURI != nil); PCM source IDs=[\(sources)]; outgoing=\(out); incoming=\(incoming); transition=\(progress); ticks=\(ticks)"
    }

    func setPreferredSeconds(_ value: Int) {
        preferredSeconds = max(2, min(12, value))
    }

    func enable() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.enable() }
            return
        }
        guard !enabled else { return }
        enabled = true
        phase = .waitingForPlayer
        lastError = ""
        lastProgress = 0
        startTimer()
    }

    func disable() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.disable() }
            return
        }
        enabled = false
        timer?.invalidate()
        timer = nil
        MixRebuildCancelNextNativePCMSourceMute()
        MixRebuildResetNativePCMSourceGains()
        if let secondaryPlayer { _ = MixRebuildStopPlayer(secondaryPlayer) }
        clearSecondary()
        mainPlayer = nil
        playerList = nil
        currentQueue = nil
        activeTrackURI = nil
        lastPrepareAttemptAt = .distantPast
        phase = .off
        lastProgress = 0
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func frontPlayer() -> NSObject? {
        if let playerList {
            if let front = playerList.perform(NSSelectorFromString("frontPlayer"))?.takeUnretainedValue() as? NSObject {
                return front
            }
            if let local = playerList.perform(NSSelectorFromString("localPlayer"))?.takeUnretainedValue() as? NSObject {
                return local
            }
        }
        return MixRebuildRegularLastPlayer() as? NSObject
    }

    private func activeSourceIDs() -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: 128)
        let count = ids.withUnsafeMutableBufferPointer { buffer -> UInt32 in
            guard let base = buffer.baseAddress else { return 0 }
            return MixRebuildReadActiveNativePCMSourceIDs(base, UInt32(buffer.count))
        }
        return Array(ids.prefix(Int(count)))
    }

    private func urlString(_ value: AnyObject?) -> String? {
        if let url = value as? NSURL { return url.absoluteString }
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String { return string }
        return nil
    }

    private func beatGrid(from track: NSObject?) -> MixRebuildBeatGrid? {
        guard let track else { return nil }
        let extensionKeys = [
            "spotify.playlistmixing.extensions.mixbeats",
            "mixbeats"
        ]
        var raw: Any?
        if let metadata = MixRebuildTrackMetadata(track) as? NSDictionary {
            for key in extensionKeys {
                if let value = metadata[key] { raw = value; break }
            }
        }
        if raw == nil {
            for key in extensionKeys {
                if let value = MixRebuildTrackMetadataValue(track, key) {
                    raw = value
                    break
                }
            }
        }
        guard let object = raw else { return nil }
        let dictionary = (object as? NSDictionary) as? [String: Any]
        guard let dictionary else { return nil }
        let nested = (dictionary["beatData"] as? [String: Any]) ??
                     (dictionary["beatsData"] as? [String: Any]) ?? dictionary
        let rawBeats = (nested["beats"] as? [[String: Any]]) ??
                       (nested["beat"] as? [[String: Any]])
        guard let rawBeats, rawBeats.count >= 8 else { return nil }
        let beatsPerBar = (nested["beatsPerBar"] as? Int) ??
                          (nested["beats_per_bar"] as? Int) ?? 4
        let bpm = (nested["bpm"] as? Double) ??
                  (nested["tempo"] as? Double) ??
                  (nested["beatsPerMinute"] as? Double) ?? 0
        let beats: [MixRebuildBeat] = rawBeats.enumerated().compactMap { index, item in
            guard let rawTime = (item["time"] as? NSNumber)?.doubleValue ??
                                (item["start"] as? NSNumber)?.doubleValue else { return nil }
            let time = rawTime > 1000 ? rawTime / 1000.0 : rawTime
            let duration = (item["duration"] as? NSNumber)?.doubleValue ?? 0
            let beatInBar = (item["beatInBar"] as? Int) ??
                            (item["positionInBar"] as? Int) ??
                            (item["beat_index"] as? Int).map { $0 % max(1, beatsPerBar) } ??
                            (index % max(1, beatsPerBar))
            let beatConfidence = (item["beatConfidence"] as? NSNumber)?.doubleValue ?? 0.8
            let downbeatConfidence = (item["downbeatConfidence"] as? NSNumber)?.doubleValue ??
                                     (beatInBar == 0 ? 0.8 : 0.1)
            return MixRebuildBeat(time: time,
                                  duration: duration > 1000 ? duration / 1000.0 : duration,
                                  beatInBar: beatInBar,
                                  beatConfidence: beatConfidence,
                                  downbeatConfidence: downbeatConfidence)
        }
        guard beats.count >= 8 else { return nil }
        let intervals = zip(beats, beats.dropFirst()).map { $1.time - $0.time }
            .filter { $0.isFinite && (0.25...1.5).contains($0) }.sorted()
        let medianInterval = intervals.isEmpty ? 0 : intervals[intervals.count / 2]
        let derivedBPM = medianInterval > 0 ? 60.0 / medianInterval : 0
        let resolvedBPM = bpm > 0 ? bpm : derivedBPM
        let confidence = beats.map(\.beatConfidence).reduce(0, +) / Double(beats.count)
        guard (70...180).contains(resolvedBPM), confidence >= 0.45 else { return nil }
        return MixRebuildBeatGrid(beats: beats, beatsPerBar: beatsPerBar,
                                  bpm: resolvedBPM, confidence: confidence)
    }

    private func normalizedMilliseconds(_ value: Double) -> Double {
        guard value.isFinite, value >= 0 else { return value }
        return value < 1000 ? value * 1000 : value
    }

    private func tick() {
        guard enabled else { return }
        ticks += 1

        if playerList == nil {
            playerList = MixRebuildRegularPlayerList() as? NSObject
        }
        if mainPlayer == nil {
            mainPlayer = frontPlayer()
            guard mainPlayer != nil else {
                phase = .waitingForPlayer
                return
            }
            activeTrackURI = urlString(MixRebuildPlayerTrackURI(mainPlayer))
            currentQueue = MixRebuildRegularPlayerQueue() as? NSObject
            phase = .waitingForQueue
        }

        guard let mainPlayer else {
            phase = .waitingForPlayer
            return
        }
        let playing = MixRebuildPlayerIsPlaying(mainPlayer)
        let position = normalizedMilliseconds(MixRebuildPlayerPositionMs(mainPlayer))
        let duration = normalizedMilliseconds(MixRebuildPlayerDurationMs(mainPlayer))
        guard playing, position >= 0, duration > 0 else {
            if secondaryPlayer == nil { phase = .waitingForPlayer }
            return
        }

        let liveURI = urlString(MixRebuildPlayerTrackURI(mainPlayer))
        if let liveURI, liveURI != activeTrackURI {
            resetForNewMainTrack(uri: liveURI)
        }
        if secondaryPlayer == nil {
            prepareNextTrack(outgoingDurationMs: duration)
        }
        if phase == .preparing || phase == .waitingForQueue || phase == .waitingForPlayer {
            discoverIncomingSourceIfPresent()
            if preparedAndReady { phase = .ready }
        }
        if phase == .ready, let overlap, position >= Double(overlap.outStartPositionMs) {
            startIncomingPlayback()
        }
        if phase == .waitingForSecondPCM {
            discoverIncomingSourceIfPresent()
            let active = activeSourceIDs()
            let bothDecksAreAudible: Bool
            if let outgoingSourceID, let incomingSourceID {
                bothDecksAreAudible = active.contains(outgoingSourceID)
                    && active.contains(incomingSourceID)
            } else {
                bothDecksAreAudible = false
            }
            let secondPlayerMatchesQueue = secondaryPlayer.map { player in
                guard let expected = incomingTrackURI,
                      let actual = urlString(MixRebuildPlayerTrackURI(player)) else { return false }
                return actual == expected && MixRebuildPlayerIsPlaying(player)
            } ?? false
            if bothDecksAreAudible && secondPlayerMatchesQueue {
                phase = .transitioning
                applyGains(progress: 0)
            } else if let playRequestedAt, Date().timeIntervalSince(playRequestedAt) > 4.0 {
                fail("Spotify did not confirm two active PCM decks for the expected queued track; outgoing playback was left alone.")
            }
        }
        if phase == .transitioning, let overlap {
            let start = Double(overlap.outStartPositionMs)
            let length = max(1.0, Double(overlap.durationMs))
            let progress = max(0, min(1, (position - start) / length))
            applyGains(progress: progress)
            if progress >= 1 { finishTransition() }
        }
    }

    private var preparedAndReady: Bool {
        secondaryPlayer != nil && incomingContext != nil && overlap != nil
    }

    private func prepareNextTrack(outgoingDurationMs: Double) {
        let now = Date()
        // The playback timer runs at 20 Hz; player-service/queue discovery does
        // not need to run at that rate when no next track is available.
        guard now.timeIntervalSince(lastPrepareAttemptAt) >= 0.5 else { return }
        lastPrepareAttemptAt = now
        guard let mainPlayer else { return }
        guard let service = MixRebuildRegularPlayerService() as? NSObject else {
            phase = .waitingForPlayer
            return
        }
        if currentQueue == nil {
            currentQueue = MixRebuildRegularPlayerQueue() as? NSObject
        }
        guard let queue = currentQueue,
              let nextTrack = MixRebuildQueueNextTrack(queue) as? NSObject,
              let nextURI = MixRebuildTrackURI(nextTrack) as AnyObject?,
              let uriString = urlString(nextURI) else {
            phase = .waitingForQueue
            return
        }
        guard let view = MixRebuildPlayerViewURI(mainPlayer),
              let feature = MixRebuildPlayerFeatureIdentifier(mainPlayer),
              let referrer = MixRebuildPlayerReferrerIdentifier(mainPlayer),
              let nextQueue = MixRebuildQueueForNextTrack(queue) as? NSObject else {
            fail("Spotify's player service did not expose the queue/context needed for a second deck.")
            return
        }
        let sourceIDs = activeSourceIDs()
        guard let outgoingID = sourceIDs.last else {
            phase = .waitingForPlayer
            return
        }
        sourceIDsBefore = Set(sourceIDs)
        registeredSourceIDsBefore = Set(registeredSourceIDs())
        guard let second = MixRebuildCreateSecondaryPlayer(service, view, feature, referrer, nextQueue) as? NSObject,
              second !== mainPlayer else {
            fail("Spotify's regular player service did not return a separate player object.")
            return
        }
        let mainTrack = MixRebuildPlayerTrack(mainPlayer) as? NSObject
        let outGrid = beatGrid(from: mainTrack)
        let inGrid = beatGrid(from: nextTrack)
        let planned = MixRebuildCore.planOverlap(
            outgoing: outGrid, incoming: inGrid,
            outgoingDurationMs: outgoingDurationMs,
            preferredSeconds: Double(preferredSeconds)
        )
        guard let context = MixRebuildCreatePlayerContext(nextURI) as? NSObject else {
            _ = MixRebuildStopPlayer(second)
            fail("Could not construct Spotify's native player context for the next queued track.")
            return
        }
        let options = MixRebuildCreatePlayOptions(
            true, Double(planned.inSpeed), Double(planned.inStartPositionMs)
        )
        guard let options else {
            _ = MixRebuildStopPlayer(second)
            fail("Could not construct paused playback options for the incoming deck.")
            return
        }
        outgoingSourceID = outgoingID
        incomingSourceID = nil
        guard MixRebuildPreparePlayer(second, context, options, view) else {
            MixRebuildCancelNextNativePCMSourceMute()
            muteArmedAt = nil
            _ = MixRebuildStopPlayer(second)
            fail("Spotify refused to prepare the incoming track; outgoing playback was left alone.")
            return
        }
        secondaryPlayer = second
        self.nextQueue = nextQueue
        incomingContext = context
        viewURI = view
        incomingTrackURI = uriString
        overlap = planned
        phase = .preparing
        lastProgress = 0
        discoverIncomingSourceIfPresent()
    }

    private func registeredSourceIDs() -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: 128)
        let count = ids.withUnsafeMutableBufferPointer { buffer -> UInt32 in
            guard let base = buffer.baseAddress else { return 0 }
            return MixRebuildReadRegisteredNativePCMSourceIDs(base, UInt32(buffer.count))
        }
        return Array(ids.prefix(Int(count)))
    }

    private func discoverIncomingSourceIfPresent() {
        guard incomingSourceID == nil else { return }
        let ids = registeredSourceIDs()
        if let newID = ids.last(where: { !registeredSourceIDsBefore.contains($0) }) {
            incomingSourceID = newID
            MixRebuildSetNativePCMSourceGain(newID, 0)
            if let outgoingSourceID { MixRebuildSetNativePCMSourceGain(outgoingSourceID, 1) }
            muteArmedAt = nil
        }
    }

    private func startIncomingPlayback() {
        guard let secondaryPlayer, let incomingContext, let viewURI, let overlap else { return }
        if incomingSourceID == nil {
            discoverIncomingSourceIfPresent()
        }
        if incomingSourceID == nil {
            MixRebuildArmNextNativePCMSourceMuted()
            muteArmedAt = Date()
        }
        let options = MixRebuildCreatePlayOptions(
            false, Double(overlap.inSpeed), Double(overlap.inStartPositionMs)
        )
        guard let options, MixRebuildPlayPlayer(secondaryPlayer, incomingContext, options, viewURI) else {
            MixRebuildCancelNextNativePCMSourceMute()
            _ = MixRebuildStopPlayer(secondaryPlayer)
            fail("The incoming Spotify player could not start; outgoing playback was left alone.")
            return
        }
        playRequestedAt = Date()
        phase = .waitingForSecondPCM
    }

    private func applyGains(progress: Double) {
        guard let outgoingSourceID, let incomingSourceID else { return }
        let gains = MixRebuildCore.gains(progress: progress)
        MixRebuildSetNativePCMSourceGain(outgoingSourceID, gains.outgoing)
        MixRebuildSetNativePCMSourceGain(incomingSourceID, gains.incoming)
        lastProgress = progress
    }

    private func finishTransition() {
        guard let oldPlayer = mainPlayer, let second = secondaryPlayer else { return }
        if let incomingSourceID { MixRebuildSetNativePCMSourceGain(incomingSourceID, 1) }
        if let outgoingSourceID { MixRebuildSetNativePCMSourceGain(outgoingSourceID, 0) }
        let promoted = playerList.map { MixRebuildPromotePlayer($0, second) } ?? false
        _ = MixRebuildStopPlayer(oldPlayer)
        mainPlayer = second
        currentQueue = nextQueue
        activeTrackURI = incomingTrackURI
        clearSecondary()
        MixRebuildResetNativePCMSourceGains()
        phase = promoted ? .waitingForQueue : .promotionFallback
        if !promoted {
            lastError = "Transition audio completed, but Spotify's player list did not confirm the new front player."
        } else {
            lastError = ""
        }
    }

    private func resetForNewMainTrack(uri: String) {
        if let secondaryPlayer { _ = MixRebuildStopPlayer(secondaryPlayer) }
        MixRebuildCancelNextNativePCMSourceMute()
        MixRebuildResetNativePCMSourceGains()
        clearSecondary()
        activeTrackURI = uri
        lastPrepareAttemptAt = .distantPast
        currentQueue = MixRebuildRegularPlayerQueue() as? NSObject
        phase = .waitingForQueue
    }

    private func clearSecondary() {
        secondaryPlayer = nil
        nextQueue = nil
        incomingContext = nil
        viewURI = nil
        incomingTrackURI = nil
        sourceIDsBefore.removeAll()
        registeredSourceIDsBefore.removeAll()
        outgoingSourceID = nil
        incomingSourceID = nil
        overlap = nil
        playRequestedAt = nil
        muteArmedAt = nil
        lastProgress = 0
    }

    private func fail(_ message: String) {
        MixRebuildCancelNextNativePCMSourceMute()
        MixRebuildResetNativePCMSourceGains()
        if let secondaryPlayer { _ = MixRebuildStopPlayer(secondaryPlayer) }
        clearSecondary()
        phase = .failed
        lastError = message
    }
}
