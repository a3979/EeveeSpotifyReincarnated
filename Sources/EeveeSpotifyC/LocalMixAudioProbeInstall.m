#import <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#import "AudioProbe.h"
#import "Diagnostics.h"
#import "fishhook.h"

// Local Beat Mix does not ship the optional diagnostics UI/trace subsystem.
// Keep the shared probe's counters disabled while allowing its PCM observer to run.
bool SAPDiagnosticsEnabled(void) { return false; }

// Install the AudioToolbox callback wrappers into Spotify's already-loaded
// image and any future images. AudioProbe.c resolves the original system
// functions with dlopen/dlsym, so these replacements never recurse.
static atomic_bool importsInstalled;

int SAPInstallSideloadAudioImports(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &importsInstalled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return 0;
    }

    struct rebinding bindings[] = {
        { "AudioUnitSetProperty", (void *)&AudioUnitSetProperty, NULL },
        { "AudioUnitGetProperty", (void *)&AudioUnitGetProperty, NULL },
        { "AudioOutputUnitStart", (void *)&AudioOutputUnitStart, NULL },
        { "AudioOutputUnitStop", (void *)&AudioOutputUnitStop, NULL },
        { "AudioComponentInstanceDispose", (void *)&AudioComponentInstanceDispose, NULL },
    };
    int result = rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
    if (result != 0) {
        atomic_store_explicit(&importsInstalled, false, memory_order_release);
    }
    return result;
}
