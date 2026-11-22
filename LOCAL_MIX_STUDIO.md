# Local Mix Studio

Local Mix Studio is an independent two-deck audio mixer built into EeveeSpotify. It uses audio files imported from the iOS Files picker; it does not use Spotify's protected streaming tracks or unlock Spotify's server-side Premium Mix service.

## Open it

1. Install the built EeveeSpotify IPA.
2. Open Spotify and go to **Settings → EeveeSpotify → Listening → Local Mix Studio**.
3. Tap **Add audio** and select audio files you own or are authorized to use.
4. Wait for waveform and approximate BPM analysis to finish.
5. Press **Play**.

## Automatic and manual mixing

- **Automatic local mixing** controls whether the playlist transitions automatically. Its state is saved with the current project and can be switched off and back on.
- Each adjacent track pair has its own **Edit mix** settings: transition duration, automatic/manual behavior, tempo matching, incoming cue, outro trim, curve, gain, EQ and effect.
- **Preview** plays the outgoing/incoming pair around its transition.
- **Mix into next track now** starts a timed transition immediately.
- The crossfader is manual once touched; the playback timer will not override its position. Move it to 100% to complete the handoff, or use **Cancel blend** to return to the outgoing track.

## Persistence and playback

- Imported audio is copied into the app's LocalMixAudio folder.
- Project order and transition settings are saved on-device.
- Exported project JSON contains the project metadata and transition settings, not the audio files. The same audio files must remain on the device to play the project.
- The shared audio engine remains alive when the editor is dismissed, so a local mix can continue while navigating elsewhere in Spotify.
- Pause Spotify's own current playback before starting a local mix to avoid hearing two unrelated playback sources at once.

## Build the Spotify 9.2.2 IPA

The CI workflow compiles the current source from this branch and then injects it into a user-supplied Spotify 9.2.2 IPA. It deliberately does not bundle or redistribute Spotify's app binary.

1. Download your own verified base IPA from your Library. The file used for this project was verified as bundle `com.spotify.client`, version `9.2.2`, build `920202587`.
2. Run `Tools/upload-spotify-922-ipa.ps1` on Windows and select that IPA. The helper uploads it to a temporary Filebin link, verifies the returned SHA-256, and prints a direct-download URL.
3. In GitHub, open **Actions → Build EeveeSpotify 7.5.0 + Local Mix Studio (Spotify 9.2.2) → Run workflow** on branch `local-mix-studio-v2`.
4. Paste the direct-download URL into `ipa_url`. The workflow checks the ZIP, bundle ID and exact Spotify version before injection.
5. Download the `EeveeSpotify-7.5.0-Spotify-9.2.2-LocalMixStudio` workflow artifact when the run succeeds.

**Privacy:** Filebin links are accessible to anyone who has the URL and expire automatically. The helper asks for confirmation before uploading and attempts to lock the bin after upload. If you do not want to use a public temporary link, use a private cloud share that provides a direct-download URL instead; do not paste a webpage URL.

The CI workflow also uploads a separate compiled `.deb` artifact after a successful source build, so a later packaging/download failure does not discard the compiled tweak.

## Important limits

- Spotify streaming tracks cannot be loaded as the two decks.
- This does not create or edit Spotify's cloud mixed playlists.
- BPM and key analysis are local estimates, not Spotify's cloud beat grid.
- The iOS build must be installed and tested on a physical iPhone to verify audio routing, background behavior and audible transitions.
