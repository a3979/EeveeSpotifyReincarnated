import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct LocalMixWaveform: Shape {
    var samples: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty, rect.width > 0 else { return path }
        let width = rect.width / CGFloat(samples.count)
        for (index, value) in samples.enumerated() {
            let magnitude = max(0.025, min(1, CGFloat(value)))
            let height = magnitude * rect.height
            let x = CGFloat(index) * width + width / 2
            path.move(to: CGPoint(x: x, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: x, y: rect.midY + height / 2))
        }
        return path
    }
}

private struct LocalMixWaveformView: View {
    let title: String
    let data: [Float]
    let tint: Color
    let bpm: Double
    let duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.caption).lineLimit(1)
                Spacer()
                Text(bpm > 0 ? "\(Int(bpm)) BPM" : "BPM unknown")
                    .foregroundColor(.secondary).font(.caption2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                    LocalMixWaveform(samples: data)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                        .padding(.vertical, 3)
                    // Approximate bar markers derived from local BPM, not Spotify's exact downbeats.
                    if bpm > 0 {
                        let analyzedDuration = max(1, min(120, duration))
                        let bars = min(128, Int(analyzedDuration * bpm / 240))
                        ForEach(0..<max(0, bars), id: \.self) { bar in
                            Rectangle()
                                .fill(Color.white.opacity(bar % 4 == 0 ? 0.26 : 0.10))
                                .frame(width: 1)
                                .position(
                                    x: geo.size.width * CGFloat(Double(bar) * 240 / bpm / analyzedDuration),
                                    y: geo.size.height / 2
                                )
                        }
                    }
                }
            }
            .frame(height: 55)
        }
    }
}

private struct EditableTrack: Identifiable {
    let id = UUID()
    let index: Int
}

struct EeveeLocalMixStudioView: View {
    @StateObject private var studio = LocalMixStudio()
    @State private var importingAudio = false
    @State private var importingProject = false
    @State private var sharing = false
    @State private var shareURL: URL?
    @State private var editTransition = false
    @State private var transitionIndex = 0
    @State private var editingTrack: EditableTrack?

    var body: some View {
        List {
            Section(header: Text("MIX STUDIO"), footer:
                Text("Two-deck local DJ mixing. Import audio files you own or are authorized to use. This editor cannot load Spotify streaming tracks or sync to Spotify's Premium cloud Mix service.")) {
                HStack {
                    Image(systemName: "waveform.path").foregroundColor(.green)
                    TextField("Name your mix", text: Binding(
                        get: { studio.project.title },
                        set: { studio.project.title = $0; studio.save() }
                    ))
                    .font(.headline)
                }
                HStack(spacing: 10) {
                    Button {
                        importingAudio = true
                    } label: {
                        Label("Add audio", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .accentColor(.green)

                    Button {
                        importingProject = true
                    } label: {
                        Label("Open mix", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
                if studio.preparing {
                    HStack { ProgressView(); Text("Analyzing waveforms and tempo...") }
                        .font(.caption)
                }
                Text(studio.diagnostic)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            if studio.project.tracks.count > 0 {
                Section(header: Text("PLAYBACK")) {
                    HStack(spacing: 18) {
                        Button { studio.isPlaying ? studio.pause() : studio.play() } label: {
                            Label(studio.isPlaying ? "Pause" : "Play", systemImage: studio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        }
                        Button { studio.stop() } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                        Button { studio.next() } label: {
                            Label("Next", systemImage: "forward.end")
                        }
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)

                    HStack {
                        Text("Track \(min(studio.currentIndex + 1, studio.project.tracks.count)) of \(studio.project.tracks.count)")
                            .font(.caption)
                        Spacer()
                        Text(time(studio.position))
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                    }
                    ProgressView(value: min(1, studio.position / max(1, studio.project.tracks[studio.currentIndex].duration)))
                        .accentColor(.green)

                    Toggle("Auto Mix entire playlist", isOn: Binding(
                        get: { studio.project.autoPlay },
                        set: { studio.project.autoPlay = $0; studio.save() }
                    ))
                    if studio.isPlaying && studio.currentIndex + 1 < studio.project.tracks.count {
                        Button("Mix into next track now") { studio.startTransition() }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text("LIVE CROSSFADER"); Spacer(); Text("\(Int(studio.fadeProgress * 100))%") }
                                .font(.caption2).foregroundColor(.secondary)
                            Slider(value: Binding(
                                get: { studio.fadeProgress },
                                set: { studio.setManualFader($0) }
                            ), in: 0...1)
                            .accentColor(.green)
                        }
                    }
                }
                Section(header: Text("PLAYLIST"), footer:
                    Text("Use Edit to drag tracks into your preferred order, or Smart Reorder to group compatible tempos and keys.")) {
                    HStack {
                        Button("Smart Reorder") { studio.smartReorder() }
                            .font(.callout).buttonStyle(.plain)
                        Spacer()
                        EditButton().font(.callout)
                    }
                    ForEach(studio.project.tracks.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(studio.project.tracks[index].title)
                                        .font(.body).fontWeight(.semibold).lineLimit(1)
                                    Text("\(time(studio.project.tracks[index].duration)) · \(bpm(studio.project.tracks[index].bpm)) · \(studio.project.tracks[index].musicalKey)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    editingTrack = EditableTrack(index: index)
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                }.buttonStyle(.borderless)
                            }
                            LocalMixWaveform(samples: studio.project.tracks[index].waveform)
                                .stroke(index % 2 == 0 ? Color.green : Color(red: 0.05, green: 0.75, blue: 0.9),
                                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                                .frame(height: 28)
                            if index + 1 < studio.project.tracks.count {
                                HStack {
                                    Label(transitionSummary(index), systemImage: "arrow.down")
                                        .font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    Button("Preview") { studio.preview(at: index) }
                                        .font(.caption).buttonStyle(.borderless)
                                    Button("Edit mix") {
                                        transitionIndex = index
                                        editTransition = true
                                    }
                                    .font(.caption).buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onMove(perform: studio.moveTracks)
                    .onDelete(perform: studio.removeTracks)
                }

                Section(header: Text("MIX COVER")) {
                    ZStack(alignment: .topLeading) {
                        LinearGradient(gradient: Gradient(colors: [.black, Color.green.opacity(0.65), Color(red: 0.1, green: 0.65, blue: 0.6)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(alignment: .leading, spacing: 12) {
                            if studio.project.sticker != "NONE" {
                                Text(studio.project.sticker)
                                    .font(.caption).bold().padding(7)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
                                    .foregroundColor(.black)
                            }
                            Spacer()
                            Text(studio.project.title.uppercased())
                                .font(.title).bold().foregroundColor(.white)
                                .lineLimit(3)
                        }
                        .padding(20)
                    }
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Picker("Mixed Edition sticker", selection: Binding(
                        get: { studio.project.sticker },
                        set: { studio.project.sticker = $0; studio.save() }
                    )) {
                        ForEach(LocalMixCoverArtwork.stickers, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    Button("Export custom cover PNG") {
                        shareURL = LocalMixCoverArtwork.export(title: studio.project.title,
                                                               sticker: studio.project.sticker)
                        sharing = shareURL != nil
                    }
                }

                Section(header: Text("SAVE & SHARE"),
                        footer: Text("Share a portable mix project file containing your transition settings and track order. Audio files are not embedded, and Spotify cloud collaboration is not supported.")) {
                    Button("Save mix project") {
                        studio.save()
                    }
                    Button("Export / share project") {
                        shareURL = studio.exportedProject()
                        sharing = shareURL != nil
                    }
                    Button("Start a new mix") {
                        studio.newProject()
                    }
                }
                if !studio.savedProjects.isEmpty {
                    Section(header: Text("SAVED MIXES")) {
                        ForEach(studio.savedProjects, id: \.self) { url in
                            HStack {
                                Text(savedName(url)).font(.callout).lineLimit(1)
                                Spacer()
                                Button("Open") { studio.loadProject(url) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Section(header: Text("ENGINE FEATURES")) {
                feature("Two-deck playback and equal-power blending", supported: true)
                feature("Automatic transitions, preview and crossfader", supported: true)
                feature("Per-transition EQ, filter, echo and reverb", supported: true)
                feature("Waveforms and approximate automatic BPM", supported: true)
                feature("Manual Camelot key tags and smart reorder", supported: true)
                feature("Save/share local mix project", supported: true)
                feature("Spotify streaming catalog as DJ decks", supported: false)
                feature("Spotify cloud mixed playlists/collaboration", supported: false)
            }
        }
        .eeveeSettingsStyle()
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: true) {
            result in if case .success(let urls) = result { studio.importFiles(urls) }
        }
        .fileImporter(isPresented: $importingProject, allowedContentTypes: [.json]) {
            result in if case .success(let url) = result { studio.loadProject(url) }
        }
        .sheet(isPresented: $editTransition) {
            NavigationView {
                EeveeMixTransitionEditor(studio: studio, index: transitionIndex)
            }
        }
        .sheet(item: $editingTrack) { item in
            NavigationView {
                EeveeMixTrackEditor(studio: studio, index: item.index)
            }
        }
        .sheet(isPresented: $sharing) {
            if let shareURL {
                LocalMixShareSheet(items: [shareURL])
            }
        }
    }

    private func savedName(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(MixStudioProject.self, from: data) else {
            return url.deletingPathExtension().lastPathComponent
        }
        return project.title
    }

    private func feature(_ name: String, supported: Bool) -> some View {
        HStack {
            Image(systemName: supported ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(supported ? .green : .secondary)
            Text(name).font(.caption)
        }
    }

    private func transitionSummary(_ index: Int) -> String {
        let setting = studio.project.transition(at: index)
        return "\(Int(setting.seconds))s · \(setting.curve.rawValue) · \(setting.effect.rawValue)"
    }

    private func bpm(_ b: Double) -> String {
        b > 0 ? "\(Int(b.rounded())) BPM" : "BPM unknown"
    }
    private func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

private struct EeveeMixTrackEditor: View {
    @ObservedObject var studio: LocalMixStudio
    let index: Int
    @Environment(\.presentationMode) private var presentation
    @State private var title: String
    @State private var bpm: Double
    @State private var camelot: String

    init(studio: LocalMixStudio, index: Int) {
        self.studio = studio
        self.index = index
        let track = studio.project.tracks[index]
        _title = State(initialValue: track.title)
        _bpm = State(initialValue: track.bpm)
        _camelot = State(initialValue: track.musicalKey)
    }

    var body: some View {
        Form {
            Section(header: Text("TRACK METADATA"), footer:
                Text("BPM is estimated from local audio. If the estimate is off, enter the actual BPM. Musical key is manually selectable in Camelot notation.")) {
                TextField("Song title", text: $title)
                HStack {
                    Text("BPM")
                    Slider(value: $bpm, in: 0...200, step: 1)
                    Text(bpm == 0 ? "?" : "\(Int(bpm))").frame(width: 32)
                }
                Picker("Musical key", selection: $camelot) {
                    Text("Unknown").tag("Unknown")
                    ForEach(1...12, id: \.self) { value in
                        Text("\(value)A").tag("\(value)A")
                        Text("\(value)B").tag("\(value)B")
                    }
                }
            }
            Section {
                Button("Save changes") {
                    var changed = studio.project.tracks[index]
                    changed.title = title
                    changed.bpm = bpm
                    changed.musicalKey = camelot
                    studio.setTrack(changed, at: index)
                    presentation.wrappedValue.dismiss()
                }
            }
        }
        .navigationBarTitle("Track details", displayMode: .inline)
    }
}

private struct EeveeMixTransitionEditor: View {
    @ObservedObject var studio: LocalMixStudio
    let index: Int
    @Environment(\.presentationMode) private var presentation
    @State private var transition: MixTransition

    init(studio: LocalMixStudio, index: Int) {
        self.studio = studio
        self.index = index
        _transition = State(initialValue: studio.project.transition(at: index))
    }

    var body: some View {
        Form {
            if index + 1 < studio.project.tracks.count {
                Section(header: Text("TRANSITION PREVIEW")) {
                    LocalMixWaveformView(title: "OUT · " + studio.project.tracks[index].title,
                                         data: studio.project.tracks[index].waveform,
                                         tint: .green,
                                         bpm: studio.project.tracks[index].bpm,
                                         duration: studio.project.tracks[index].duration)
                    LocalMixWaveformView(title: "IN · " + studio.project.tracks[index + 1].title,
                                         data: studio.project.tracks[index + 1].waveform,
                                         tint: Color(red: 0.05, green: 0.75, blue: 0.90),
                                         bpm: studio.project.tracks[index + 1].bpm,
                                         duration: studio.project.tracks[index + 1].duration)
                    Button("Preview these two songs") {
                        persist()
                        studio.preview(at: index)
                    }
                }
            }
            Section(header: Text("QUICK STYLES")) {
                HStack {
                    Button("Smooth") { applyPreset("smooth") }.buttonStyle(.plain)
                    Button("Club") { applyPreset("club") }.buttonStyle(.plain)
                    Button("Radio") { applyPreset("radio") }.buttonStyle(.plain)
                }
            }
            Section(header: Text("TIMING")) {
                HStack {
                    Text("Transition length")
                    Slider(value: $transition.seconds, in: 0.5...24, step: 0.5)
                    Text("\(transition.seconds, specifier: "%.1f")s")
                        .frame(width: 43)
                }
                Toggle("Auto Mix this transition", isOn: $transition.automatic)
                Toggle("Beatmatch / preserve pitch", isOn: $transition.syncTempo)
                HStack {
                    Text("Next track start")
                    Slider(value: $transition.incomingCue, in: 0...min(45,
                        max(0.5, studio.project.tracks[index + 1].duration - 1)), step: 0.5)
                    Text("\(Int(transition.incomingCue))s").frame(width: 32)
                }
                HStack {
                    Text("Outro trim")
                    Slider(value: $transition.outroTrim, in: 0...15, step: 0.5)
                    Text("\(Int(transition.outroTrim))s").frame(width: 32)
                }
            }
            Section(header: Text("VOLUME & CURVES")) {
                Picker("Curve", selection: $transition.curve) {
                    ForEach(MixCurve.allCases) { curve in
                        Text(curve.rawValue).tag(curve)
                    }
                }
                HStack {
                    Text("Gain")
                    Slider(value: $transition.gain, in: 0.3...1, step: 0.05)
                    Text("\(Int(transition.gain * 100))%")
                }
            }
            Section(header: Text("EQ & EFFECTS")) {
                Picker("Effect style", selection: $transition.effect) {
                    ForEach(MixEffect.allCases) { effect in
                        Text(effect.rawValue).tag(effect)
                    }
                }
                gainControl("Bass", value: $transition.bass)
                gainControl("Mids", value: $transition.mids)
                gainControl("Highs", value: $transition.highs)
            }
            Section(footer: Text("All of these settings affect the local two-deck audio engine. They cannot add Spotify's server-authorized transitions to a Spotify streaming playlist.")) {
                Button("Save transition") {
                    persist()
                    presentation.wrappedValue.dismiss()
                }
                Button("Use automatic defaults") {
                    transition = MixTransition()
                    persist()
                }
            }
        }
        .navigationBarTitle("Mix transition", displayMode: .inline)
        .onDisappear { persist() }
    }

    private func applyPreset(_ preset: String) {
        switch preset {
        case "club":
            transition.seconds = 12
            transition.curve = .equalPower
            transition.effect = .bassSwap
            transition.syncTempo = true
        case "radio":
            transition.seconds = 3
            transition.curve = .linear
            transition.effect = .none
            transition.syncTempo = false
        default:
            transition.seconds = 8
            transition.curve = .smooth
            transition.effect = .none
            transition.syncTempo = true
        }
        persist()
    }

    private func gainControl(_ title: String, value: Binding<Float>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: -18...18, step: 1)
            Text("\(Int(value.wrappedValue)) dB")
                .foregroundColor(.secondary).frame(width: 46)
        }
    }
    private func persist() {
        studio.project.setTransition(transition, at: index)
        studio.save()
    }
}

private struct LocalMixShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ viewController: UIActivityViewController, context: Context) {}
}
