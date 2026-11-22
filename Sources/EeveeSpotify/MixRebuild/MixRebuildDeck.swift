import AVFoundation
import Combine
import Foundation

/// The only music sources this deck accepts are audio files that the user
/// imports through the iOS Files picker. Spotify's protected streamed audio
/// is neither copied nor decrypted by this class.
struct MixRebuildTrack: Identifiable, Codable, Sendable {
    let id: UUID
    let storedName: String
    let title: String
    let duration: Double
    let tempo: MixRebuildTempo

    init(storedName: String, title: String, duration: Double, tempo: MixRebuildTempo) {
        id = UUID()
        self.storedName = storedName
        self.title = title
        self.duration = duration
        self.tempo = tempo
    }
}

enum MixRebuildFileAnalysis {
    static func inspect(_ url: URL) -> (duration: Double, tempo: MixRebuildTempo)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, rate.isFinite,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            return nil
        }
        let duration = Double(file.length) / rate
        // Only analyze up to two minutes of a user-imported local file.
        let limit = Int64(min(120, duration) * rate)
        let interval = max(1, Int(rate / 50))
        let envelopeHz = rate / Double(interval)
        var envelope = [Double]()
        envelope.reserveCapacity(Int(min(120, duration) * envelopeHz) + 1)
        var framesRead: Int64 = 0
        var sumSquares = 0.0
        var samples = 0

        while framesRead < limit {
            let size = AVAudioFrameCount(min(Int64(4096), limit - framesRead))
            do { try file.read(into: buffer, frameCount: size) }
            catch { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let audio = buffer.floatChannelData?[0] else { break }
            for i in 0..<count {
                if i % 8 == 0 {
                    let value = Double(audio[i])
                    if value.isFinite { sumSquares += min(1, value * value) }
                    samples += 1
                }
                if (framesRead + Int64(i) + 1) % Int64(interval) == 0 {
                    envelope.append(sqrt(sumSquares / Double(max(samples, 1))))
                    sumSquares = 0
                    samples = 0
                }
            }
            framesRead += Int64(count)
        }
        return (duration, MixRebuildCore.estimateTempo(energy: envelope, envelopeHz: envelopeHz))
    }
}

@MainActor
final class MixRebuildDeck: ObservableObject {
    static let shared = MixRebuildDeck()

    @Published private(set) var tracks: [MixRebuildTrack] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var transitioning = false
    @Published private(set) var position = 0.0
    @Published private(set) var progress = 0.0
    @Published private(set) var importing = false
    @Published private(set) var message = "Import at least two audio files"
    @Published var automatic = true
    @Published var preferredSeconds: Double = 6

    private let engine = AVAudioEngine()
    private let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private let timePitches = [AVAudioUnitTimePitch(), AVAudioUnitTimePitch()]
    private var files: [AVAudioFile?] = [nil, nil]
    private var startPositions = [0.0, 0.0]
    private var activeSlot = 0
    private var fadeStarted = 0.0
    private var fadeLength = 1.0
    private var timer: Timer?

    private static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MixRebuild", isDirectory: true)
    }
    private static var manifest: URL {
        folder.appendingPathComponent("library.json")
    }
    private func fileURL(_ track: MixRebuildTrack) -> URL {
        Self.folder.appendingPathComponent(track.storedName)
    }

    private init() {
        for i in 0..<2 {
            engine.attach(players[i])
            engine.attach(timePitches[i])
            engine.connect(players[i], to: timePitches[i], format: nil)
            engine.connect(timePitches[i], to: engine.mainMixerNode, format: nil)
            players[i].volume = i == 0 ? 1 : 0
        }
        engine.prepare()
        if let data = try? Data(contentsOf: Self.manifest),
           let loaded = try? JSONDecoder().decode([MixRebuildTrack].self, from: data) {
            tracks = loaded.filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(tracks).write(to: Self.manifest, options: .atomic)
        } catch {
            message = "Couldn't save imported tracks: \(error.localizedDescription)"
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !importing else { return }
        importing = true
        let destination = Self.folder
        Task {
            let added = await Task.detached(priority: .utility) { () -> [MixRebuildTrack] in
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var imported = [MixRebuildTrack]()
                for url in urls {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let targetName = UUID().uuidString + "-" + url.lastPathComponent
                    let target = destination.appendingPathComponent(targetName)
                    do {
                        try FileManager.default.copyItem(at: url, to: target)
                        guard let info = MixRebuildFileAnalysis.inspect(target) else {
                            try? FileManager.default.removeItem(at: target)
                            continue
                        }
                        imported.append(MixRebuildTrack(storedName: targetName,
                                                          title: url.deletingPathExtension().lastPathComponent,
                                                          duration: info.duration, tempo: info.tempo))
                    } catch {
                        try? FileManager.default.removeItem(at: target)
                    }
                }
                return imported
            }.value
            tracks.append(contentsOf: added)
            importing = false
            persist()
            message = added.isEmpty ? "No compatible audio files found" :
                "Imported \(added.count) local audio file(s)"
        }
    }

    private func startEngine() throws {
        if !engine.isRunning {
            // Spotify already controls the app's AVAudioSession. We don't
            // impersonate or override its session/category in the DJ engine.
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        }
        if timer == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func cue(index: Int, on slot: Int, at seconds: Double) throws {
        let track = tracks[index]
        let file = try AVAudioFile(forReading: fileURL(track))
        let offset = min(max(0, seconds), max(0, track.duration - 0.25))
        let startingFrame = min(Int64(offset * file.processingFormat.sampleRate), file.length - 1)
        let frames = AVAudioFrameCount(min(Int64(UInt32.max), max(1, file.length - startingFrame)))
        players[slot].stop()
        files[slot] = file
        startPositions[slot] = offset
        timePitches[slot].rate = 1
        players[slot].scheduleSegment(file, startingFrame: startingFrame, frameCount: frames,
                                      at: nil, completionHandler: nil)
        players[slot].volume = 0
    }

    private func played(slot: Int) -> Double {
        guard let renderTime = players[slot].lastRenderTime,
              let playerTime = players[slot].playerTime(forNodeTime: renderTime) else {
            return startPositions[slot]
        }
        return startPositions[slot] +
            Double(playerTime.sampleTime) / max(playerTime.sampleRate, 1)
    }

    func play() {
        guard !tracks.isEmpty else { message = "Import a local audio file first"; return }
        guard !isPlaying else { return }
        do {
            try startEngine()
            if currentIndex >= tracks.count { currentIndex = 0 }
            activeSlot = 0
            try cue(index: currentIndex, on: activeSlot, at: position)
            players[activeSlot].volume = 1
            players[activeSlot].play()
            isPlaying = true
            message = "Playing local audio · \(tracks[currentIndex].title)"
        } catch {
            message = "Audio player error: \(error.localizedDescription)"
        }
    }

    func pause() {
        guard isPlaying else { return }
        if transitioning && progress >= 0.5 && currentIndex + 1 < tracks.count {
            let incoming = 1 - activeSlot
            position = played(slot: incoming)
            currentIndex += 1
        } else {
            position = played(slot: activeSlot)
        }
        for player in players { player.stop() }
        isPlaying = false
        transitioning = false
        progress = 0
        message = "Paused"
    }

    func stop() {
        for player in players { player.stop() }
        isPlaying = false
        transitioning = false
        progress = 0
        position = 0
        activeSlot = 0
        message = "Stopped"
    }

    func next() {
        guard currentIndex + 1 < tracks.count else {
            stop()
            message = "End of local playlist"
            return
        }
        stop()
        currentIndex += 1
        play()
    }

    private func plan() -> MixRebuildPlan? {
        guard currentIndex + 1 < tracks.count else { return nil }
        let outgoing = tracks[currentIndex], incoming = tracks[currentIndex + 1]
        return MixRebuildCore.plan(outgoing: outgoing.tempo, incoming: incoming.tempo,
                                   preferredSeconds: preferredSeconds,
                                   availableSeconds: max(0.25, outgoing.duration - position))
    }

    func startTransition() {
        guard isPlaying, !transitioning, currentIndex + 1 < tracks.count,
              let transition = plan() else { return }
        do {
            let newSlot = 1 - activeSlot
            try cue(index: currentIndex + 1, on: newSlot, at: 0)
            timePitches[newSlot].rate = transition.incomingRate
            fadeLength = transition.seconds
            fadeStarted = ProcessInfo.processInfo.systemUptime
            progress = 0
            transitioning = true
            players[newSlot].play()
            message = "\(transition.style.rawValue) · \(String(format: "%.1f", fadeLength))s"
        } catch {
            message = "Couldn't start mix: \(error.localizedDescription)"
            transitioning = false
        }
    }

    private func finishTransition() {
        let outgoingSlot = activeSlot
        let incomingSlot = 1 - outgoingSlot
        players[outgoingSlot].stop()
        files[outgoingSlot] = nil
        players[outgoingSlot].volume = 0
        players[incomingSlot].volume = 1
        activeSlot = incomingSlot
        currentIndex += 1
        position = played(slot: incomingSlot)
        transitioning = false
        progress = 0
        message = "Now playing · \(tracks[currentIndex].title)"
    }

    private func tick() {
        guard isPlaying, tracks.indices.contains(currentIndex) else { return }
        position = played(slot: activeSlot)
        if transitioning {
            let elapsed = ProcessInfo.processInfo.systemUptime - fadeStarted
            progress = min(1, max(0, elapsed / max(0.25, fadeLength)))
            let gain = MixRebuildCore.gains(progress: progress)
            players[activeSlot].volume = gain.outgoing
            players[1 - activeSlot].volume = gain.incoming
            if progress >= 1 || position >= tracks[currentIndex].duration - 0.05 {
                finishTransition()
            }
            return
        }
        let remaining = tracks[currentIndex].duration - position
        if automatic, let transition = plan(),
           remaining <= transition.seconds && remaining > 0 {
            startTransition()
        } else if remaining <= 0.10 {
            if currentIndex + 1 < tracks.count { next() }
            else { stop(); message = "Reached end of local playlist" }
        }
    }

    func remove(at offsets: IndexSet) {
        stop()
        for index in offsets where tracks.indices.contains(index) {
            try? FileManager.default.removeItem(at: fileURL(tracks[index]))
        }
        tracks.remove(atOffsets: offsets)
        currentIndex = 0
        persist()
    }
}
