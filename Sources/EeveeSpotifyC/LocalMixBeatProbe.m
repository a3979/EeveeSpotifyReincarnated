// Local Beat Mix experiment: listen to Spotify's already-decoded PCM from the
// optional AudioProbe companion, estimate pulse and adapt native crossfade.
// No track downloading, entitlement forgery or network service required.
// This does NOT create Spotify's Premium Mix editor or provide two-deck mixing.
#include <AudioToolbox/AudioToolbox.h>
#include <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

typedef void (*LocalPCMObserver)(const AudioStreamBasicDescription *, AudioBufferList *, UInt32);
typedef void (*LocalProbeSetter)(LocalPCMObserver);

static LocalProbeSetter setProbeObserver;
static _Atomic(bool) enabled;
static _Atomic(bool) registered;
static _Atomic(uint_fast64_t) lastGateTick, lastAudioTick, lastPulseTick;
static _Atomic(int) tempoTenths, confidence;
static _Atomic(double) baselineLevel, previousLevel;
static uint64_t ticksPerSecond;

static double clampDouble(double v, double lo, double hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

// Runs on the render thread. No allocation, locks, UI, logging or network calls.
static void capturePCM(const AudioStreamBasicDescription *format, AudioBufferList *audio, UInt32 frames) {
    if (!atomic_load_explicit(&enabled, memory_order_relaxed) || !format || !audio ||
        format->mFormatID != kAudioFormatLinearPCM ||
        !(format->mFormatFlags & kAudioFormatFlagIsPacked) ||
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        audio->mNumberBuffers == 0 || audio->mNumberBuffers > 32 ||
        format->mBytesPerFrame == 0) return;

    bool floats = (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mBitsPerChannel == 32;
    bool ints16 = (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) && format->mBitsPerChannel == 16;
    if (!floats && !ints16) return;

    uint64_t now = mach_absolute_time();
    atomic_store_explicit(&lastAudioTick, now, memory_order_relaxed);
    uint64_t earlier = atomic_load_explicit(&lastGateTick, memory_order_relaxed);
    uint64_t minTicks = ticksPerSecond / 35; // <=35 analyses/s regardless of buffer rate.
    if (earlier && now - earlier < minTicks) return;
    if (!atomic_compare_exchange_strong_explicit(&lastGateTick, &earlier, now,
                                                 memory_order_acq_rel, memory_order_relaxed)) return;

    const AudioBuffer *buffer = &audio->mBuffers[0];
    if (!buffer->mData) return;
    uint32_t bytesPerSample = floats ? 4 : 2;
    uint32_t count = buffer->mDataByteSize / bytesPerSample;
    if (!count) return;
    uint32_t stride = count > 128 ? count / 128 : 1;
    double magnitude = 0;
    uint32_t observations = 0;
    for (uint32_t i = 0; i < count && observations < 128; i += stride) {
        double v = 0;
        if (floats) {
            float sample = 0;
            memcpy(&sample, (const char *)buffer->mData + i * 4, 4);
            v = fabs((double)sample);
        } else {
            int16_t sample = 0;
            memcpy(&sample, (const char *)buffer->mData + i * 2, 2);
            v = fabs((double)sample / 32768.0);
        }
        if (isfinite(v)) magnitude += fmin(v, 1.0);
        observations++;
    }
    if (!observations) return;
    magnitude /= observations;
    double baseline = atomic_load_explicit(&baselineLevel, memory_order_relaxed);
    double previous = atomic_load_explicit(&previousLevel, memory_order_relaxed);
    atomic_store_explicit(&baselineLevel, baseline * 0.965 + magnitude * 0.035, memory_order_relaxed);
    atomic_store_explicit(&previousLevel, magnitude, memory_order_relaxed);

    // Causal onset envelope heuristic; not a spectral BPM detector.
    if (magnitude < 0.018 || magnitude <= baseline * 1.60 ||
        magnitude < previous * 1.24) return;

    uint64_t last = atomic_load_explicit(&lastPulseTick, memory_order_relaxed);
    if (last && now - last < ticksPerSecond / 4) return; // ignore duplicate attacks.
    atomic_store_explicit(&lastPulseTick, now, memory_order_relaxed);
    if (!last) return;

    double delta = (double)(now - last) / (double)ticksPerSecond;
    if (delta < 0.30 || delta > 1.20) return;
    double estimated = 60.0 / delta;
    while (estimated < 75.0) estimated *= 2.0;
    while (estimated > 170.0) estimated /= 2.0;

    int prior = atomic_load_explicit(&tempoTenths, memory_order_relaxed);
    int next = (int)lrint(estimated * 10.0);
    int matches = prior && fabs((double)prior - next) < prior * 0.14;
    int conf = atomic_load_explicit(&confidence, memory_order_relaxed);
    atomic_store_explicit(&tempoTenths, matches ? (prior * 3 + next) / 4 : next,
                          memory_order_relaxed);
    atomic_store_explicit(&confidence, matches ? (conf < 12 ? conf + 1 : 12)
                                              : (conf > 0 ? conf - 1 : 0), memory_order_relaxed);
}

static void attachProbe(void) {
    if (setProbeObserver) return;
    void *symbol = dlsym(RTLD_DEFAULT, "SpotifyAudioProbeSetObserver");
    if (!symbol) {
        NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
        NSString *path = [frameworks stringByAppendingPathComponent:@"SpotifyAudioProbe.dylib"];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_NOLOAD);
        if (handle) symbol = dlsym(handle, "SpotifyAudioProbeSetObserver");
    }
    if (symbol) setProbeObserver = (LocalProbeSetter)symbol;
}

void EeveeLocalMixSetEnabled(bool on) {
    atomic_store_explicit(&enabled, on, memory_order_release);
    if (!ticksPerSecond) {
        mach_timebase_info_data_t info = {0};
        mach_timebase_info(&info);
        ticksPerSecond = info.numer ? (uint64_t)(1000000000.0 * info.denom / info.numer) : 1000000000ULL;
    }
    if (!on) {
        if (setProbeObserver && atomic_exchange(&registered, false)) setProbeObserver(NULL);
        return;
    }
    attachProbe();
    if (setProbeObserver && !atomic_exchange(&registered, true))
        setProbeObserver(capturePCM);
}

int EeveeLocalMixProbeState(void) {
    if (!atomic_load(&registered)) return 0;
    uint64_t recent = atomic_load(&lastAudioTick);
    return recent && mach_absolute_time() - recent < ticksPerSecond * 5 ? 2 : 1;
}

int EeveeLocalMixEstimatedBPM(void) {
    if (EeveeLocalMixProbeState() != 2 || atomic_load(&confidence) < 3) return 0;
    return atomic_load(&tempoTenths) / 10;
}

int EeveeLocalMixSuggestCrossfadeSeconds(int requested, int beats) {
    if (requested <= 0 || !atomic_load(&enabled)) return requested;
    int bpm = EeveeLocalMixEstimatedBPM();
    if (!bpm) return requested;
    if (beats != 4 && beats != 8 && beats != 16) beats = 8;
    int seconds = (int)lrint(60.0 * beats / bpm);
    return (int)clampDouble(seconds, 2, 12);
}
