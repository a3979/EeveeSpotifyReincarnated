#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include "AudioProbe.h"
#include "fishhook.h"
#import "Tweak.h"

// Diagnostics are enabled only while the user's playlist Mix switch is on.
// The probe records bounded RMS envelopes and counters; it never stores audio.
static atomic_bool mixDiagnosticsEnabled = ATOMIC_VAR_INIT(false);
bool SAPDiagnosticsEnabled(void) {
    return atomic_load_explicit(&mixDiagnosticsEnabled, memory_order_relaxed);
}
void MixRebuildSetDiagnosticsEnabled(BOOL enabled) {
    atomic_store_explicit(&mixDiagnosticsEnabled, enabled, memory_order_relaxed);
}
void MixRebuildReadPCMEnvelope(double *values, uint32_t capacity,
                               uint32_t *sampleCount, double *sampleHz) {
    SpotifyAudioProbeReadEnergyEnvelope(values, capacity, sampleCount, sampleHz);
}

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
         @"AudioUnit callback registrations: %u | callbacks: %llu | frames: %llu | PCM bytes: %llu | "
        @"peak: %.3f | format: %u | rate: %.0f Hz | channels: %u | sample age: %.2fs | "
        @"scheduled PCM callbacks: %llu / %llu",
        atomic_load(&installState),
        snapshot.backendReady ? @"ready" : @"unavailable",
        snapshot.pcmConfirmed ? @"yes" : @"unverified",
        snapshot.registrations, native, external,
        snapshot.callbackAttempts,
        (unsigned long long)snapshot.callbacks,
        (unsigned long long)snapshot.frames,
        (unsigned long long)snapshot.pcmBytes,
        (double)snapshot.peakMillionths / 1000000.0,
        snapshot.formatID, snapshot.sampleRate, snapshot.channels,
        snapshot.lastCallbackAgeSeconds,
        (unsigned long long)snapshot.sampleBufferCalls,
        (unsigned long long)snapshot.playerBufferCalls];
}
