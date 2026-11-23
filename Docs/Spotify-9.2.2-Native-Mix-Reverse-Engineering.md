# Spotify 9.2.2 native Mix reverse-engineering notes

## Source examined

The Spotify 9.2.2 app executable was extracted from the existing EeveeSpotify
build artifact. The build pipeline replaces Eevee's injected tweak/framework
payloads; it does not patch Spotify's Spotify executable. The inspected Mach-O
therefore contains Spotify's own compiled code and metadata.

The scan covered Mach-O sections, Objective-C class/method metadata, Swift
nominal type descriptors and field descriptors, and embedded strings/protobuf
type names.

## Native feature topology

The native feature is not a crossfade-preference setter:

- MixingPermissionsHandlerImpl owns the feature permission decision.
- MixingAutoMixEvaluatorImpl evaluates automatic-mix eligibility.
- MixingCoreAutomixTransitionLoader owns an automixClient.
- MixingAutomixTransitionLoader owns both an automixClient and the core loader.
- MixingTransitionParserImpl parses the transition recipe.
- MixingTransitionPlayerServiceImpl receives the regular SPTPlayerService.
- MixingTransitionPlayerImpl owns a separate SPTPlayer plus its context URI,
  play-generation state, and active MixingPlayingTransitionContext.

The native loader references Esperanto calls such as GetComputedTransitions,
GetMixingBundle, and AdjustTransitionRecipeForItemSpeeds. Those are
server-assisted recipe/style services. The local implementation must not
depend on those calls.

MediaPlaybackMixer is a separate Spotify type found in an unrelated Wrapped
Places scene. It is not a stored dependency of MixingTransitionPlayerImpl;
do not assume it is the playlist Mix audio engine.

## Native transition data recovered

MixingPlayingTransitionContext stores trackA, trackB, hadPreviousContext,
and previewMode.

MixingCoreAutomixTrackPair stores outgoing and incoming track URLs and
per-item playback speeds.

MixingOverlap stores outgoing/incoming start positions, outgoing/incoming
speeds, overlap duration and duration in bars, beat-match state, outgoing and
incoming track URIs, playable-beat hashes, BPM, and item speeds.

BeatData stores a beat array and BPM. ProtoBeats stores beats-per-bar, beat
data, and a beat hash. ProtoBeat exposes time, duration, beat position, beat
confidence, and downbeat confidence.

The executable also contains playlist metadata extension names for mixbeats,
mixstate, mixability, mixvocalactivity, and audio_attributes.v2 (including
musical key/Camelot-key metadata).

## Reusable normal-player interfaces

The executable exposes these Objective-C-visible interfaces:

- SPTPlayerServiceImplementation.providePlayerWithViewURI:featureIdentifier:referrerIdentifier:queue:
- SPTPlayerServiceImplementation.providePlayerQueue
- SPTPlayerServiceImplementation.providePlayerListWithViewURI:featureIdentifier:referrerIdentifier:queue:
- SPTEsperantoPlayer.preparePlaybackOfContext:options:viewURI:
- SPTEsperantoPlayer.playContext:options:viewURI:
- SPTEsperantoPlayer.resume:, stop, and seekTo:
- SPTPlayerListImplementation.players, frontPlayer, localPlayer, and updateIdentifiers:frontIdentifier:localIdentifier:
- SPTPlayerQueueImplementation.track, prevTracks, and nextTracks
- SPTPlayerContext.initWithDictionary:
- SPTPlayOptions.initiallyPaused, playbackSpeed, and seekTo

The local design mirrors the native topology: keep the normal deck, request a
second player from the regular player service, prepare the next queued track,
and transition between independently decoded output paths. It uses local
beat-grid metadata when present and falls back to a plain equal-power fade
when reliable beat metadata is unavailable.

## Safety and verification boundary

The local engine does not extract, save, or export decoded audio, obtain DRM
keys, or spoof Spotify subscription permissions. PCM processing is limited to
in-memory per-player output gain. Two separate active PCM paths must be
observed before a transition is attempted; otherwise the current player is
left untouched.
