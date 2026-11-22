#import <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#import "AudioProbe.h"

// Small, read-only bridge for Local Beat Mix. AVAudioHooks observes buffers
// as Spotify schedules them; the observer only samples amplitude and never
// changes protected audio. Returning false avoids copying every scheduled
// buffer, keeping the disabled path and normal playback overhead minimal.
static _Atomic(SAPPCMObserver) localMixObserver;

void SpotifyAudioProbeSetObserver(SAPPCMObserver observer) {
    atomic_store_explicit(&localMixObserver, observer, memory_order_release);
}

bool SAPWantsMutableBuffers(void) {
    // The Local Beat Mix analyzer is read-only.
    return false;
}

void SAPProcessExternal(const void *identity, const char *path,
                        const AudioStreamBasicDescription *format,
                        AudioBufferList *buffers, UInt32 frames, bool writable) {
    (void)identity;
    (void)path;
    (void)writable;
    if (!format || !buffers || frames == 0) return;
    SAPPCMObserver observer = atomic_load_explicit(&localMixObserver, memory_order_acquire);
    if (observer) observer(format, buffers, frames);
}

void SAPNoteObjCHooks(unsigned count) {
    (void)count;
}

void SAPNoteScheduledBuffer(bool sampleBuffer, uint32_t formatID) {
    (void)sampleBuffer;
    (void)formatID;
}

void SAPNoteExtractionError(void) {
    // Playback remains untouched if an unsupported buffer cannot be inspected.
}
