import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Mix Studio is a local-file DJ engine, NOT an entitlement unlock for Spotify
// streaming or the official mixed-playlist cloud service.

enum MixCurve: String, Codable, CaseIterable, Identifiable {
    case equalPower = "Equal power"
    case linear = "Linear"
    case smooth = "S-curve"
    case cut = "Hard cut"
    var id: String { rawValue }
}

enum MixEffect: String, Codable, CaseIterable, Identifiable {
    case none = "Clean"
    case bassSwap = "Bass swap"
    case filter = "Filter sweep"
    case echo = "Echo out"
    case reverb = "Reverb tail"
    var id: String { rawValue }
}

struct MixTrack: Identifiable, Codable, Equatable {
    var id = UUID()
    var file: String
    var title: String
    var duration: Double
    var bpm: Double = 0
    var musicalKey: String = "Unknown"
    var waveform: [Float] = []
}

struct MixTransition: Codable, Equatable {
    var seconds: Double = 8
    var curve: MixCurve = .equalPower
    var effect: MixEffect = .bassSwap
    var automatic: Bool = true
    var syncTempo: Bool = true
    var incomingCue: Double = 0
    var outroTrim: Double = 0
    var bass: Float = 0
    var mids: Float = 0
    var highs: Float = 0
    var gain: Float = 1
}

struct MixStudioProject: Identifiable, Codable {
    var id = UUID()
    var title = "My Mix"
    var tracks: [MixTrack] = []
    var transitions: [String: MixTransition] = [:]
    var updated = Date()
    var autoPlay = true
    var sticker = "MIXED EDITION"

    func transitionKey(at index: Int) -> String? {
        guard index >= 0, index + 1 < tracks.count else { return nil }
        return tracks[index].id.uuidString + ":" + tracks[index + 1].id.uuidString
    }
    func transition(at index: Int) -> MixTransition {
        guard let key = transitionKey(at: index) else { return MixTransition() }
        return transitions[key] ?? MixTransition()
    }
    mutating func setTransition(_ value: MixTransition, at index: Int) {
        guard let key = transitionKey(at: index) else { return }
        transitions[key] = value
        updated = Date()
    }
}

enum LocalMixAnalysis {
    // An inexpensive local onset-envelope analysis. Approximate BPM, not
    // Spotify's cloud beat grid. Never fabricates a key: unknown until entered.
    static func analyze(_ url: URL) -> (duration: Double, wave: [Float], bpm: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return (0, [], 0) }
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / max(sampleRate, 1)
        let format = file.processingFormat
        guard sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            return (duration, [], 0)
        }
        var levels = [Double]()
        var total: Int64 = 0
        let limit = Int64(min(duration, 120) * sampleRate)
        let window = max(128, Int(sampleRate / 40))
        var aggregate = 0.0
        var gathered = 0
        while total < limit {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, limit - total))) }
            catch { break }
            let length = Int(buffer.frameLength)
            guard length > 0 else { break }
            if let data = buffer.floatChannelData?[0] {
                for frame in 0..<length {
                    // 1 in 8 sample energy estimates; can run on a utility queue.
                    if frame % 8 == 0 {
                        let v = Double(data[frame])
                        if v.isFinite { aggregate += min(1, v * v) }
                        gathered += 1
                    }
                    if (total + Int64(frame) + 1) % Int64(window) == 0 {
                        levels.append(sqrt(aggregate / Double(max(gathered, 1))))
                        aggregate = 0
                        gathered = 0
                    }
                }
            }
            total += Int64(length)
        }
        if levels.isEmpty { return (duration, [], 0) }
        let buckets = 112
        var wave = [Float]()
        for b in 0..<buckets {
            let begin = b * levels.count / buckets
            let end = min(levels.count, max(begin + 1, (b + 1) * levels.count / buckets))
            if begin >= levels.count { wave.append(0); continue }
            wave.append(Float(min(1, (levels[begin..<end].max() ?? 0) * 3.2)))
        }

        // Onset strength of the amplitude envelope, autocorrelated over 65–180 BPM.
        let mean = levels.reduce(0, +) / Double(levels.count)
        let onset = zip(levels.dropFirst(), levels).map { max(0, $0 - $1 - mean * 0.07) }
        guard onset.count > 100 else { return (duration, wave, 0) }
        let envHz = sampleRate / Double(window)
        let lower = max(1, Int(envHz * 60 / 180))
        let upper = min(onset.count / 3, Int(envHz * 60 / 65))
        guard lower <= upper else { return (duration, wave, 0) }
        var bestLag = 0
        var best = 0.0
        for lag in lower...upper {
            var correlation = 0.0
            for i in lag..<onset.count { correlation += onset[i] * onset[i - lag] }
            if correlation > best { best = correlation; bestLag = lag }
        }
        let energy = onset.reduce(0) { $0 + $1 * $1 }
        let confidence = energy > 0 ? best / energy : 0
        let bpm = (bestLag > 0 && confidence > 0.08)
            ? (60 * envHz / Double(bestLag)) : 0
        return (duration, wave, bpm)
    }
}

@MainActor final class LocalMixStudio: ObservableObject {
    @Published var project = MixStudioProject()
    @Published var isPlaying = false
    @Published var isTransitioning = false
    @Published var isPreview = false
    @Published var currentIndex = 0
    @Published var position = 0.0
    @Published var fadeProgress = 0.0
    @Published var diagnostic = "Import audio files to begin"
    @Published var preparing = false
    @Published var savedProjects: [URL] = []

    private let engine = AVAudioEngine()
    private let decks = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private let pitches = [AVAudioUnitTimePitch(), AVAudioUnitTimePitch()]
    private let equalizers = [AVAudioUnitEQ(numberOfBands: 4), AVAudioUnitEQ(numberOfBands: 4)]
    private let echoes = [AVAudioUnitDelay(), AVAudioUnitDelay()]
    private let reverbs = [AVAudioUnitReverb(), AVAudioUnitReverb()]
    private var openFiles: [AVAudioFile?] = [nil, nil]
    private var startOffsets: [Double] = [0, 0]
    private var activeDeck = 0
    private var fadeStartedAt = 0.0
    private var fadeDuration = 0.0
    private var lastPreviewIndex = -1
    private var tickTimer: Timer?
    private var lastSaved: Date = .distantPast

    private static let folderName = "LocalMixAudio"
    static var projectFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMixStudio.json")
    }
    static var audioFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }
    static var projectFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMixProjects", isDirectory: true)
    }

    init() {
        setupEngine()
        load()
    }

    private func setupEngine() {
        for slot in 0..<2 {
            let player = decks[slot], pitch = pitches[slot], eq = equalizers[slot]
            let delay = echoes[slot], reverb = reverbs[slot]
            engine.attach(player)
            engine.attach(pitch)
            engine.attach(eq)
            engine.attach(delay)
            engine.attach(reverb)
            engine.connect(player, to: pitch, format: nil)
            engine.connect(pitch, to: eq, format: nil)
            engine.connect(eq, to: delay, format: nil)
            engine.connect(delay, to: reverb, format: nil)
            engine.connect(reverb, to: engine.mainMixerNode, format: nil)

            let bands = eq.bands
            bands[0].filterType = .lowShelf
            bands[0].frequency = 180
            bands[1].filterType = .parametric
            bands[1].frequency = 1100
            bands[1].bandwidth = 0.9
            bands[2].filterType = .highShelf
            bands[2].frequency = 6000
            bands[3].filterType = .lowPass
            bands[3].frequency = 19000
            for band in bands { band.bypass = false }
            delay.wetDryMix = 0
            delay.feedback = 24
            delay.delayTime = 0.3
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 0
            player.volume = slot == 0 ? 1 : 0
        }
        engine.prepare()
    }

    private func ensureStarted() throws {
        if !engine.isRunning {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        }
        if tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.075, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func trackURL(_ track: MixTrack) -> URL {
        Self.audioFolder.appendingPathComponent(track.file)
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        preparing = true
        try? FileManager.default.createDirectory(at: Self.audioFolder,
                                                  withIntermediateDirectories: true)
        let audioFolder = Self.audioFolder
        Task.detached(priority: .utility) { [weak self] in
            var loaded = [MixTrack]()
            for url in urls {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let filename = UUID().uuidString + "-" + url.lastPathComponent
                let target = audioFolder.appendingPathComponent(filename)
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    let result = LocalMixAnalysis.analyze(target)
                    guard result.duration > 0 else { continue }
                    let musicalKey = LocalMixKeyAnalyzer.estimate(target)
                    let title = url.deletingPathExtension().lastPathComponent
                    loaded.append(MixTrack(file: filename, title: title, duration: result.duration,
                                           bpm: result.bpm, musicalKey: musicalKey, waveform: result.wave))
                } catch { continue }
            }
            await MainActor.run {
                self?.project.tracks.append(contentsOf: loaded)
                self?.preparing = false
                self?.diagnostic = loaded.isEmpty
                    ? "No compatible audio files were imported"
                    : "Imported \(loaded.count) audio tracks"
                self?.save()
            }
        }
    }

    func setTrack(_ value: MixTrack, at index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        project.tracks[index] = value
        save()
    }

    func moveTracks(from offsets: IndexSet, to index: Int) {
        project.tracks.move(fromOffsets: offsets, toOffset: index)
        save()
    }

    func removeTracks(at indices: IndexSet) {
        stop()
        for index in indices {
            if project.tracks.indices.contains(index) {
                try? FileManager.default.removeItem(at: trackURL(project.tracks[index]))
            }
        }
        project.tracks.remove(atOffsets: indices)
        currentIndex = 0
        save()
    }

    func smartReorder() {
        guard project.tracks.count > 2 else { return }
        stop()
        var remaining = Array(project.tracks.dropFirst())
        var ordered = [project.tracks[0]]
        while !remaining.isEmpty {
            let current = ordered.last!
            let best = remaining.indices.min { a, b in
                score(current, remaining[a]) < score(current, remaining[b])
            }!
            ordered.append(remaining.remove(at: best))
        }
        project.tracks = ordered
        diagnostic = "Reordered by approximate BPM and manually entered key"
        save()
    }

    private func score(_ a: MixTrack, _ b: MixTrack) -> Double {
        let bpmScore: Double
        if a.bpm > 0 && b.bpm > 0 {
            bpmScore = abs(log(a.bpm / b.bpm)) * 80
        } else { bpmScore = 15 }
        return bpmScore + (compatibleKey(a.musicalKey, b.musicalKey) ? 0 : 15)
    }

    private func compatibleKey(_ a: String, _ b: String) -> Bool {
        guard a.count >= 2, b.count >= 2,
              let n = Int(a.dropLast()), let m = Int(b.dropLast()) else { return true }
        let adj = abs(n - m)
        return n == m || ((a.last == b.last) && (adj == 1 || adj == 11))
    }

    private func schedule(_ index: Int, on slot: Int, at seconds: Double) throws {
        guard project.tracks.indices.contains(index) else { return }
        let url = trackURL(project.tracks[index])
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw NSError(domain: "LocalMix", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty audio file"]) }
        let start = min(max(0, seconds), max(0, project.tracks[index].duration - 0.25))
        let startFrame = min(Int64(start * file.processingFormat.sampleRate), file.length - 1)
        let remain = max(1, file.length - startFrame)
        let frameCount = AVAudioFrameCount(min(remain, Int64(UInt32.max)))
        decks[slot].stop()
        pitches[slot].rate = 1
        pitches[slot].pitch = 0
        openFiles[slot] = file
        startOffsets[slot] = start
        decks[slot].scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount,
                                    at: nil, completionHandler: nil)
        decks[slot].volume = slot == activeDeck ? 1 : 0
    }

    private func played(on slot: Int) -> Double {
        guard let nodeTime = decks[slot].lastRenderTime,
              let playTime = decks[slot].playerTime(forNodeTime: nodeTime) else {
            return startOffsets[slot]
        }
        return startOffsets[slot] + Double(playTime.sampleTime) / max(playTime.sampleRate, 1)
    }

    func play() {
        guard !project.tracks.isEmpty else { diagnostic = "Add audio tracks first"; return }
        do {
            try ensureStarted()
            if !isPlaying {
                if currentIndex >= project.tracks.count { currentIndex = 0 }
                activeDeck = 0
                try schedule(currentIndex, on: 0, at: position)
                decks[0].volume = 1
                decks[1].volume = 0
                decks[0].play()
                isPlaying = true
                isPreview = false
                diagnostic = "Playing local Mix Studio project"
            }
        } catch { diagnostic = "Audio engine error: \(error.localizedDescription)" }
    }

    func pause() {
        guard isPlaying else { return }
        if isTransitioning {
            // Resume from outgoing deck's current location rather than a half-scheduled pair.
            position = played(on: activeDeck)
            isTransitioning = false
        } else { position = played(on: activeDeck) }
        decks.forEach { $0.stop() }
        isPlaying = false
        isPreview = false
    }

    func stop() {
        decks.forEach { $0.stop() }
        position = 0
        isPlaying = false
        isTransitioning = false
        isPreview = false
        fadeProgress = 0
        activeDeck = 0
    }

    func next() {
        guard currentIndex + 1 < project.tracks.count else { stop(); return }
        stop()
        currentIndex += 1
        play()
    }

    func preview(at index: Int) {
        guard index + 1 < project.tracks.count else { return }
        stop()
        do {
            try ensureStarted()
            currentIndex = index
            activeDeck = 0
            isPreview = true
            lastPreviewIndex = index
            let outgoing = project.tracks[index]
            let transition = project.transition(at: index)
            let startAt = max(0, outgoing.duration - transition.seconds - 2.0 - transition.outroTrim)
            try schedule(index, on: 0, at: startAt)
            position = startAt
            decks[0].volume = 1
            decks[0].play()
            isPlaying = true
            diagnostic = "Previewing transition \(index + 1)"
        } catch { diagnostic = "Preview failed: \(error.localizedDescription)" }
    }

    func startTransition() {
        guard isPlaying && !isTransitioning,
              currentIndex + 1 < project.tracks.count else { return }
        do {
            let nextDeck = 1 - activeDeck
            let next = currentIndex + 1
            let setting = project.transition(at: currentIndex)
            try schedule(next, on: nextDeck, at: setting.incomingCue)
            if setting.syncTempo {
                let a = project.tracks[currentIndex].bpm
                let b = project.tracks[next].bpm
                if a > 0 && b > 0 {
                    let ratio = a / b
                    pitches[nextDeck].rate = Float(min(1.10, max(0.90, ratio)))
                }
            }
            fadeDuration = max(0.25, setting.seconds)
            fadeStartedAt = played(on: activeDeck)
            isTransitioning = true
            fadeProgress = 0
            decks[nextDeck].volume = 0
            decks[nextDeck].play()
        } catch { diagnostic = "Transition failed: \(error.localizedDescription)" }
    }

    func setManualFader(_ progress: Double) {
        guard isPlaying else { return }
        if !isTransitioning { startTransition() }
        guard isTransitioning else { return }
        applyTransition(progress: min(1, max(0, progress)))
    }

    private func applyTransition(progress p: Double) {
        let setting = project.transition(at: currentIndex)
        fadeProgress = p
        var outGain: Double
        var inGain: Double
        switch setting.curve {
        case .linear: outGain = 1 - p; inGain = p
        case .equalPower: outGain = cos(p * .pi / 2); inGain = sin(p * .pi / 2)
        case .smooth:
            let s = p * p * (3 - 2 * p)
            outGain = cos(s * .pi / 2); inGain = sin(s * .pi / 2)
        case .cut: outGain = p < 0.5 ? 1 : 0; inGain = p < 0.5 ? 0 : 1
        }
        let from = activeDeck, to = 1 - from
        outGain *= Double(setting.gain)
        inGain *= Double(setting.gain)
        decks[from].volume = Float(max(0, min(1, outGain)))
        decks[to].volume = Float(max(0, min(1, inGain)))

        let sourceEQ = equalizers[from].bands, targetEQ = equalizers[to].bands
        // The same per-transition EQ can be edited independently of the style.
        sourceEQ[0].gain = -max(0, setting.bass) * Float(p)
        sourceEQ[1].gain = -max(0, setting.mids) * Float(p)
        sourceEQ[2].gain = -max(0, setting.highs) * Float(p)
        targetEQ[0].gain = setting.bass * Float(1 - p)
        targetEQ[1].gain = setting.mids * Float(1 - p)
        targetEQ[2].gain = setting.highs * Float(1 - p)

        switch setting.effect {
        case .none:
            echoes[from].wetDryMix = 0; reverbs[from].wetDryMix = 0
            sourceEQ[3].frequency = 19000
        case .bassSwap:
            sourceEQ[0].gain = -18 * Float(p)
            targetEQ[0].gain = -18 * Float(1 - p)
        case .filter:
            sourceEQ[3].frequency = Float(19000 * pow(300.0 / 19000, p))
            targetEQ[3].frequency = Float(500 * pow(19000.0 / 500, p))
        case .echo:
            echoes[from].wetDryMix = Float(45 * p)
            echoes[to].wetDryMix = 0
        case .reverb:
            reverbs[from].wetDryMix = Float(40 * p)
            reverbs[to].wetDryMix = 0
        }
    }

    private func resetEffects() {
        for eq in equalizers {
            for band in eq.bands { band.gain = 0 }
            eq.bands[3].frequency = 19000
        }
        for d in echoes { d.wetDryMix = 0 }
        for r in reverbs { r.wetDryMix = 0 }
        for pitch in pitches { pitch.rate = 1 }
    }

    private func finishTransition() {
        guard isTransitioning else { return }
        let finished = activeDeck
        let incoming = 1 - finished
        decks[finished].stop()
        decks[finished].volume = 0
        decks[incoming].volume = 1
        activeDeck = incoming
        currentIndex += 1
        position = played(on: incoming)
        isTransitioning = false
        fadeProgress = 0
        resetEffects()
        if isPreview {
            // A preview ends after the transition; do not play the whole playlist.
            pause()
            diagnostic = "Preview complete"
        }
    }

    private func tick() {
        guard isPlaying, project.tracks.indices.contains(currentIndex) else { return }
        position = played(on: activeDeck)
        if isTransitioning {
            let p = (position - fadeStartedAt) / max(fadeDuration, 0.1)
            applyTransition(progress: min(1, max(0, p)))
            if p >= 1 { finishTransition() }
            return
        }
        let outgoing = project.tracks[currentIndex]
        let left = outgoing.duration - position
        if left <= 0.20 {
            if currentIndex + 1 < project.tracks.count { next() }
            else { stop(); diagnostic = "Reached the end of your mix" }
            return
        }
        let setting = project.transition(at: currentIndex)
        if (isPreview || (project.autoPlay && setting.automatic))
            && currentIndex + 1 < project.tracks.count
            && left <= setting.seconds + setting.outroTrim {
            startTransition()
        }
    }

    func save() {
        project.updated = Date()
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: Self.projectFile, options: .atomic)
        try? FileManager.default.createDirectory(at: Self.projectFolder, withIntermediateDirectories: true)
        let archive = Self.projectFolder.appendingPathComponent(project.id.uuidString + ".json")
        try? data.write(to: archive, options: .atomic)
        reloadSavedProjects()
        lastSaved = Date()
    }

    func reloadSavedProjects() {
        let all = (try? FileManager.default.contentsOfDirectory(at: Self.projectFolder,
                  includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        savedProjects = all.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { ($0.lastPathComponent) < ($1.lastPathComponent) }
    }

    func newProject() {
        stop()
        project = MixStudioProject()
        currentIndex = 0
        diagnostic = "Started a new local mix"
        save()
    }

    func load() {
        reloadSavedProjects()
        guard let data = try? Data(contentsOf: Self.projectFile),
              let decoded = try? JSONDecoder().decode(MixStudioProject.self, from: data)
        else { return }
        project = decoded
    }

    func loadProject(_ url: URL) {
        stop()
        let grant = url.startAccessingSecurityScopedResource()
        defer { if grant { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MixStudioProject.self, from: data)
        else { diagnostic = "Not a valid Mix Studio project"; return }
        project = decoded
        currentIndex = 0
        diagnostic = "Loaded project metadata. Imported audio must still be on this device."
        save()
    }

    func exportedProject() -> URL? {
        save()
        let title = project.title.replacingOccurrences(of: "/", with: "-")
        let url = Self.audioFolder.deletingLastPathComponent()
            .appendingPathComponent("\(title)-MixStudio.json")
        guard let data = try? JSONEncoder().encode(project),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}
