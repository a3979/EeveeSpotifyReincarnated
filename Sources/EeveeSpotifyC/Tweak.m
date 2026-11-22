#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#import "Tweak.h"

#if NO_JBROOT
// Sideloaded IPA: no jailbreak-only library imports.
#elif THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <libroot.h>
#endif

NSString *EeveeJBRootPath(NSString *path) {
#if NO_JBROOT
    return path;
#elif THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return JBROOT_PATH_NSSTRING(path);
#endif
}

// Typed primitive ObjC calls; NSObject.perform would corrupt scalar arguments.
// The playlist Mix toggle only requests Spotify's existing crossfade. It does
// not enable Spotify's Premium cloud Mix or guarantee two audio tracks overlap.
// Diagnostic introspection only. Do not invoke unknown Swift selectors: their
// signatures have not been verified and could crash Spotify. This captures
// available Objective-C methods for the native transition player/UI so we can
// determine whether the bundled Spotify code is usable on a Free account.
NSString *MixRebuildDescribeNativeMixClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return @"Objective-C class enumeration unavailable";
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    for (unsigned int i = 0; i < count && results.count < 25; i++) {
        const char *name = class_getName(classes[i]);
        if (!name || (!strstr(name, "MixingTransitionPlayer") &&
                      !strstr(name, "MixingEditViewController") &&
                      !strstr(name, "MixButtonElement") &&
                      !strstr(name, "MixingTransitionService"))) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        NSMutableArray<NSString *> *selectors = [NSMutableArray array];
        for (unsigned int j = 0; j < methodCount && selectors.count < 14; j++) {
            SEL selector = method_getName(methods[j]);
            if (selector) [selectors addObject:NSStringFromSelector(selector)];
        }
        if (methods) free(methods);
        [results addObject:[NSString stringWithFormat:@"%s (%u methods): %@",
                            name, methodCount, [selectors componentsJoinedByString:@", "]]];
    }
    free(classes);
    return results.count ? [results componentsJoinedByString:@"\n"]
                         : @"No native mixing classes exposed to Objective-C runtime";
}

// On some Spotify Free paths the crossfade getters are never invoked. A
// preference object may still be constructed through Swift dependency
// injection, so observe *only verified* ObjC initializer/injector signatures.
// Never swizzle an inherited NSObject method or call an unknown ABI.
static __weak id mixObservedPreference;
static id (*mixOriginalPreferenceInit)(id, SEL) = NULL;
static void (*mixOriginalPreferenceInject)(id, SEL, id) = NULL;
static atomic_uint mixPreferenceCaptureEvents;

static id mixCapturedPreferenceInit(id receiver, SEL command) {
    id result = mixOriginalPreferenceInit(receiver, command);
    if (result) { mixObservedPreference = result; atomic_fetch_add_explicit(&mixPreferenceCaptureEvents, 1, memory_order_relaxed); }
    return result;
}
static void mixCapturedPreferenceInject(id receiver, SEL command, id provider) {
    mixOriginalPreferenceInject(receiver, command, provider);
    mixObservedPreference = receiver;
    mixPreferenceCaptureEvents++;
}

int MixRebuildInstallPreferenceCapture(void) {
    Class cls = objc_getClass("_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation");
    if (!cls) return -1;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    int bits = 0;
    for (unsigned int i = 0; i < count; ++i) {
        SEL sel = method_getName(methods[i]);
        const char *enc = method_getTypeEncoding(methods[i]);
        if (!sel || !enc) continue;
        NSString *name = NSStringFromSelector(sel);
        if ([name isEqualToString:@"init"] &&
            strstr(enc, "@16@0:8") == enc && !mixOriginalPreferenceInit) {
            mixOriginalPreferenceInit = (id (*)(id, SEL))method_getImplementation(methods[i]);
            method_setImplementation(methods[i], (IMP)mixCapturedPreferenceInit);
            bits |= 1;
        }
        if ([name isEqualToString:@"_injectDependenciesWithProvider:"] &&
            strstr(enc, "v24@0:8@16") == enc && !mixOriginalPreferenceInject) {
            mixOriginalPreferenceInject = (void (*)(id, SEL, id))method_getImplementation(methods[i]);
            method_setImplementation(methods[i], (IMP)mixCapturedPreferenceInject);
            bits |= 2;
        }
    }
    free(methods);
    return bits;
}
id MixRebuildObservedPreferenceObject(void) { return mixObservedPreference; }
unsigned int MixRebuildPreferenceCaptureEvents(void) { return atomic_load_explicit(&mixPreferenceCaptureEvents, memory_order_relaxed); }

NSInteger MixRebuildReadNativeCrossfadeTimeOrNeg1(id target) {
    SEL selector = NSSelectorFromString(@"audioCrossfadeTime");
    if (!target || ![target respondsToSelector:selector]) return -1;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(target, selector);
}
int MixRebuildReadNativeCrossfadeEnabledOrNeg1(id target) {
    SEL selector = NSSelectorFromString(@"audioCrossfade");
    if (!target || ![target respondsToSelector:selector]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector) ? 1 : 0;
}

int MixRebuildReadNativeCrossfade(id target, NSInteger *milliseconds, BOOL *enabled) {
    if (!target || !milliseconds || !enabled) return 0;
    SEL time = NSSelectorFromString(@"audioCrossfadeTime");
    SEL state = NSSelectorFromString(@"audioCrossfade");
    if (![target respondsToSelector:time] || ![target respondsToSelector:state]) return 0;
    *milliseconds = ((NSInteger (*)(id, SEL))objc_msgSend)(target, time);
    *enabled = ((BOOL (*)(id, SEL))objc_msgSend)(target, state);
    return 1;
}

void MixRebuildSetNativeCrossfadeTime(id target, NSInteger milliseconds) {
    SEL sel = NSSelectorFromString(@"setAudioCrossfadeTime:");
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, sel, milliseconds);
}

void MixRebuildSetNativeCrossfadeEnabled(id target, BOOL enabled) {
    SEL sel = NSSelectorFromString(@"setAudioCrossfade:");
    if (!target || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, enabled);
}

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) {
    if (!target || !selector) return;
    typedef id (*SeekFn)(id, SEL, double);
    SeekFn fn = (SeekFn)objc_msgSend;
    (void)fn(target, selector, argument);
}

BOOL EeveeSetMainInfoValue(NSString *key, id value) {
    @try {
        id info = (__bridge id)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
        if (![info isKindOfClass:NSMutableDictionary.class]) return NO;
        [(NSMutableDictionary *)info setObject:value forKey:key];
        return [[NSBundle.mainBundle objectForInfoDictionaryKey:key] isEqual:value];
    } @catch (NSException *e) {
        return NO;
    }
}

static void writeDebugLog(NSString *message) {
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void init() {
    @try {
        NSLog(@"[EeveeSpotify] Initializing tweak...");

        // Initialize Orion - do not remove this line.
        orion_init();

        NSLog(@"[EeveeSpotify] Tweak initialized successfully");
        // Custom initialization code goes here.
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        NSLog(@"[EeveeSpotify] %@", errorMsg);
        writeDebugLog(errorMsg);
    }
}
