import Combine
import EeveeSpotifyC
import SwiftUI

/// Experimental local tempo-aware crossfade. Uses Spotify's existing
/// crossfade renderer, not the Premium playlist Mix editor.
struct EeveeLocalMixSettingsView: View {
    @State private var enabled = LocalMixRuntime.enabled
    @State private var beats = LocalMixRuntime.beats
    @State private var probe = 0
    @State private var bpm = 0

    private func refresh() {
        probe = Int(EeveeLocalMixProbeState())
        bpm = Int(EeveeLocalMixEstimatedBPM())
    }

    var body: some View {
        List {
            Section(
                header: Text("Local Beat Mix"),
                footer: Text("Local Beat Mix analyzes scheduled audio on your iPhone and adjusts Spotify's existing crossfade. It does not call Spotify's cloud Mix service or unlock the Premium Mix editor.")
            ) {
                Toggle("Enable local beat transitions", isOn: $enabled)
                Picker("Transition length", selection: $beats) {
                    Text("4 beats").tag(4)
                    Text("8 beats").tag(8)
                    Text("16 beats").tag(16)
                }
                .disabled(!enabled)
            }

            Section(header: Text("Live analysis"),
                    footer: Text("A BPM reading confirms PCM sampling, not successful crossfading. Spotify Free may refuse native overlapping playback despite a crossfade request.")) {
                HStack {
                    Text("Audio probe")
                    Spacer()
                    Text(probe == 2 ? "Receiving audio" : probe == 1 ? "Waiting for playback" : "Unavailable")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Estimated tempo")
                    Spacer()
                    Text(bpm > 0 ? "\(bpm) BPM" : "Learning...")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Native crossfade request")
                    Spacer()
                    Text(LocalMixRuntime.nativeRequestStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Original crossfade")
                    Spacer()
                    Text(LocalMixRuntime.savedCrossfadeStatus)
                        .foregroundColor(.secondary)
                }
                Button("Apply updated transition timing") {
                    LocalMixRuntime.tick()
                    refresh()
                }
                .disabled(!enabled || bpm == 0)
            }

            Section(
                footer: Text("Local Beat Mix requests Spotify's native crossfade when enabled. Start a playlist and let the analyzer listen for a stable tempo. It then adjusts the crossfade duration toward the selected 4/8/16-beat window. If no reliable tempo is detected, your saved crossfade duration is retained.")
            ) {
                Text("Spotify's own playback engine performs the overlap. This prototype controls crossfade timing locally; independent streaming decks, per-track cue points, EQ automation and Spotify's cloud mixed-playlist editor are not implemented.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onAppear {
            if enabled { LocalMixRuntime.setEnabled(true) }
            refresh()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .eeveeLocalMixStateChanged)) { _ in
            enabled = LocalMixRuntime.enabled
            beats = LocalMixRuntime.beats
            refresh()
        }
        .onChange(of: enabled) { newValue in
            LocalMixRuntime.setEnabled(newValue)
            refresh()
        }
        .onChange(of: beats) { newValue in
            LocalMixRuntime.setBeats(newValue)
        }
    }
}
