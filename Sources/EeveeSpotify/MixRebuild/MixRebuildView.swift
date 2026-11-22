import SwiftUI
import UniformTypeIdentifiers

/// A real, fully local two-deck mixer. The source must be an audio file the
/// user imported; this is not Spotify Premium's playlist-mixing UI.
struct MixRebuildView: View {
    @StateObject private var mixer = MixRebuildDeck.shared
    @State private var showImporter = false

    var body: some View {
        List {
            Section(header: Text("MIX REBUILD"),
                    footer: Text("This engine plays imported audio on two independent decks. Spotify streaming tracks are not available to this engine as audio files. Pause regular Spotify playback before playing a local mix.")) {
                HStack {
                    Image(systemName: "waveform.path")
                        .foregroundColor(.green)
                    Text("Independent two-deck mixing").bold()
                }
                Text(mixer.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    showImporter = true
                } label: {
                    Label(mixer.importing ? "Importing and analyzing..." : "Import audio from Files",
                          systemImage: "square.and.arrow.down")
                }
                .disabled(mixer.importing)
            }

            Section(header: Text("PLAYBACK")) {
                HStack(spacing: 18) {
                    Button {
                        mixer.isPlaying ? mixer.pause() : mixer.play()
                    } label: {
                        Label(mixer.isPlaying ? "Pause" : "Play",
                              systemImage: mixer.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button {
                        mixer.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    Button {
                        mixer.next()
                    } label: {
                        Label("Next", systemImage: "forward.end.fill")
                    }
                    .disabled(mixer.currentIndex + 1 >= mixer.tracks.count)
                }
                .buttonStyle(.borderless)
                .disabled(mixer.tracks.isEmpty)

                HStack {
                    Text("Position")
                    Spacer()
                    Text(timestamp(mixer.position))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                if mixer.isPlaying && mixer.currentIndex < mixer.tracks.count {
                    ProgressView(
                        value: min(1, mixer.position / max(0.01, mixer.tracks[mixer.currentIndex].duration))
                    )
                    if mixer.transitioning {
                        VStack(alignment: .leading) {
                            Text("Mixing two decks · \(Int(mixer.progress * 100))%")
                                .font(.caption).foregroundColor(.secondary)
                            ProgressView(value: mixer.progress)
                        }
                    } else if mixer.currentIndex + 1 < mixer.tracks.count {
                        Button("Mix into the next song now") { mixer.startTransition() }
                    }
                }
            }

            Section(header: Text("AUTOMATION"),
                    footer: Text("Tempo-paced transitions require reliable BPM estimates from both imported files. If tempos don't match, the mixer uses a gentle or quick crossfade instead of pretending to synchronize beats.")) {
                Toggle("Automatically mix into next song", isOn: $mixer.automatic)
                HStack {
                    Text("Maximum transition")
                    Spacer()
                    Text("\(Int(mixer.preferredSeconds)) sec")
                        .foregroundColor(.secondary)
                }
                Slider(value: $mixer.preferredSeconds, in: 2...12, step: 1)
                    .disabled(!mixer.automatic)
            }

            Section(header: Text("IMPORTED TRACKS"),
                    footer: Text("Swipe to remove an imported track. Files are copied into the app's local storage, and the track list is restored after relaunch.")) {
                if mixer.tracks.isEmpty {
                    Text("No imported songs yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(mixer.tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(alignment: .center) {
                            Image(systemName: index == mixer.currentIndex && mixer.isPlaying
                                  ? "waveform" : "music.note")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title)
                                    .lineLimit(1)
                                Text("\(timestamp(track.duration)) · \(tempoText(track.tempo))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete(perform: mixer.remove)
                }
            }
        }
        .eeveeSettingsStyle()
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): mixer.importFiles(urls)
            case .failure: break
            }
        }
    }

    private func tempoText(_ reading: MixRebuildTempo) -> String {
        reading.bpm > 0 ? "\(Int(reading.bpm.rounded())) BPM (est.)" : "Unknown BPM"
    }

    private func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
