#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include "AudioProbe.h"
#include "fishhook.h"
#import "Tweak.h"

// The read-only audit does not save audio, modify PCM, download Spotify tracks,
// or invoke Premium playlist transitions. It observes established Core Audio
// source callbacks solely to identify possible concurrent PCM paths.
bool SAPDiagnosticsEnabled(void) { return false; }

extern void SAPReadActivePCMSourceCounts(uint32_t *native, uint32_t *external);
static atomic_int installState = ATOMIC_VAR_INIT(-100);

int MixRebuildInstallPlaybackProbe(void) {
    int expected = -100;
    if (!atomic_compare_exchange_strong(&installState, &expected, -101)) {
        return expected;
    }
    SpotifyAudioProbeInitialize();
    struct rebinding bindings[] = {
        {"AudioUnitSetProperty", (void *)&AudioUnitSetProperty, NULL},
        {"AudioUnitGetProperty", (void *)&AudioUnitGetProperty, NULL},
        {"AudioOutputUnitStart", (void *)&AudioOutputUnitStart, NULL},
        {"AudioOutputUnitStop", (void *)&AudioOutputUnitStop, NULL},
        {"AudioComponentInstanceDispose", (void *)&AudioComponentInstanceDispose, NULL},
    };
    int status = rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
    // AVFoundation may schedule compressed streams as well as PCM. These
    // hooks only report PCM-positive sources and preserve original audio.
    SAPInstallAVHooks();
    atomic_store(&installState, status);
    return status;
}

int MixRebuildActiveNativePCMPaths(void) {
    uint32_t native = 0, external = 0;
    SAPReadActivePCMSourceCounts(&native, &external);
    return (int)native;
}

int MixRebuildActiveAVFoundationPCMPaths(void) {
    uint32_t native = 0, external = 0;
    SAPReadActivePCMSourceCounts(&native, &external);
    return (int)external;
}

NSString *MixRebuildPlaybackMonitorStatus(void) {
    SAPSnapshot snapshot = {0};
    SpotifyAudioProbeReadSnapshot(&snapshot);
    uint32_t native = 0, external = 0;
    SAPReadActivePCMSourceCounts(&native, &external);
    return [NSString stringWithFormat:
        @"Hook status: %d | backend: %@ | PCM observed: %@ | "
        @"registered paths: %u | native active: %u | AVFoundation active: %u | "
         @"AudioUnit callback registrations: %u | PCM schedule callbacks: %llu / %llu",
        atomic_load(&installState),
        snapshot.backendReady ? @"ready" : @"unavailable",
        snapshot.pcmConfirmed ? @"yes" : @"unverified",
        snapshot.registrations, native, external,
        snapshot.callbackAttempts,
        (unsigned long long)snapshot.sampleBufferCalls,
        (unsigned long long)snapshot.playerBufferCalls];
}
