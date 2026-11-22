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
                footer: Text("Experimental beat-aware crossfade for Spotify playback. Runs on your iPhone using decoded audio, not Spotify's cloud Mix service. It is not the Premium Mix editor.")
            ) {
                Toggle("Enable local beat transitions", isOn: $enabled)
                Picker("Transition length", selection: $beats) {
                    Text("4 beats").tag(4)
                    Text("8 beats").tag(8)
                    Text("16 beats").tag(16)
                }
                .disabled(!enabled)
            }

            Section(header: Text("Live analysis")) {
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
                Button("Apply updated transition timing") {
                    LocalMixRuntime.tick()
                    refresh()
                }
                .disabled(!enabled || bpm == 0)
            }

            Section(
                footer: Text("To arm the crossfade, open Spotify Settings → Playback, switch Crossfade on and move its duration above zero once. Play a song with a steady beat while the probe learns. At the next stable update, Local Beat Mix adjusts Spotify's native crossfade duration toward 4/8/16 beats. If it cannot detect tempo, Spotify's original crossfade stays in control.")
            ) {
                Text("This is a client-side prototype. A smooth overlap is possible only when Spotify's normal crossfade engine works; manual EQ, cue points, saving mixed playlists and cloud Mix features are not included.")
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
        .onChange(of: enabled) { newValue in
            LocalMixRuntime.setEnabled(newValue)
            refresh()
        }
        .onChange(of: beats) { newValue in
            LocalMixRuntime.setBeats(newValue)
        }
    }
}
