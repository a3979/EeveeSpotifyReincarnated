#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <dispatch/dispatch.h>
#import "Tweak.h"
#import "AudioProbe.h"
#include <math.h>

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
static BOOL MixRebuildIsRelevantPlayerClass(const char *name) {
    if (!name) return NO;
    const char *needles[] = {
        "MixingTransitionPlayer", "MixingEditViewController", "MixButtonElement",
        "MixingTransitionService", "SPTPlayerFactory", "SPTPlayerServiceImplementation",
        "SPTPlayerListImplementation", "SPTPlayerQueueImplementation", "SPTPlayerContextProvider",
        "SPTPlayerPlay", "SPTPlayerMftCanPlayCheckerImplementation",
        "SPTPlayerPositionStateImplementation", "SPTPlayerSubscriptionImplementation",
        "SPTEsperantoPlayer"
    };
    for (unsigned i = 0; i < sizeof(needles) / sizeof(needles[0]); ++i)
        if (strstr(name, needles[i])) return YES;
    return NO;
}

static NSString *MixRebuildDescribeMethodList(Class cls, BOOL classMethods) {
    Class owner = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    NSMutableArray<NSString *> *descriptions = [NSMutableArray array];
    for (unsigned int i = 0; i < count && descriptions.count < 24; ++i) {
        SEL selector = method_getName(methods[i]);
        const char *encoding = method_getTypeEncoding(methods[i]);
        if (selector) {
            [descriptions addObject:[NSString stringWithFormat:@"%@ [%s]",
                NSStringFromSelector(selector), encoding ?: "?"]];
        }
    }
    if (methods) free(methods);
    return [NSString stringWithFormat:@"%u: %@", count, [descriptions componentsJoinedByString:@", "]];
}

NSString *MixRebuildDescribeNativeMixClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return @"Objective-C class enumeration unavailable";
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    for (unsigned int i = 0; i < count && results.count < 40; i++) {
        const char *name = class_getName(classes[i]);
        if (!MixRebuildIsRelevantPlayerClass(name)) continue;
        NSString *instanceMethods = MixRebuildDescribeMethodList(classes[i], NO);
        NSString *classMethods = MixRebuildDescribeMethodList(classes[i], YES);
        [results addObject:[NSString stringWithFormat:@"%s | instance methods %@ | class methods %@",
                            name, instanceMethods, classMethods]];
    }
    free(classes);
    return results.count ? [results componentsJoinedByString:@"\n"]
                         : @"No native mixing/player classes exposed to Objective-C runtime";
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


// Read-only observation of Spotify's ordinary (non-Premium) player service.
// Observing the creation of multiple player proxies is NOT proof that two
// decoded tracks are playing; do not alter the player, session or content.
static atomic_int mixRegularPlayerInstall = ATOMIC_VAR_INIT(-100);
static atomic_uint mixRegularPlayerInjectionCalls;
static atomic_uint mixRegularPlayerRequests;
static atomic_uint mixRegularPlayerResults;
static atomic_uint mixRegularListRequests;
static atomic_uint mixRegularListResults;
static NSHashTable *mixRegularLivePlayers;
static NSHashTable *mixRegularLiveLists;
static NSObject *mixRegularLock;
static __weak id mixRegularPlayerService;
static __weak id mixRegularPlayerQueue;
static __weak id mixRegularPlayerList;
static __weak id mixRegularLastPlayer;
static id (*mixOriginalProvidePlayer)(id, SEL, id, id, id, id);
static id (*mixOriginalProvideList)(id, SEL, id, id, id, id);
static id (*mixOriginalProvideQueue)(id, SEL);
static void (*mixOriginalRegularInjection)(id, SEL, id);

static void mixRegularEnsureStore(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mixRegularLock = [NSObject new];
        mixRegularLivePlayers = [NSHashTable weakObjectsHashTable];
        mixRegularLiveLists = [NSHashTable weakObjectsHashTable];
    });
}
static void mixRegularRecordObject(id object, BOOL isList) {
    if (!object) return;
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) {
        [(isList ? mixRegularLiveLists : mixRegularLivePlayers) addObject:object];
    }
}
static id mixRegularObserveProvidePlayer(id self, SEL sel, id uri, id feature, id referrer, id queue) {
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { mixRegularPlayerService = self; }
    atomic_fetch_add_explicit(&mixRegularPlayerRequests, 1, memory_order_relaxed);
    id result = mixOriginalProvidePlayer(self, sel, uri, feature, referrer, queue);
    if (result) {
        @synchronized(mixRegularLock) { mixRegularLastPlayer = result; }
        atomic_fetch_add_explicit(&mixRegularPlayerResults, 1, memory_order_relaxed);
        mixRegularRecordObject(result, NO);
    }
    return result;
}
static id mixRegularObserveProvideList(id self, SEL sel, id uri, id feature, id referrer, id queue) {
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { mixRegularPlayerService = self; }
    atomic_fetch_add_explicit(&mixRegularListRequests, 1, memory_order_relaxed);
    id result = mixOriginalProvideList(self, sel, uri, feature, referrer, queue);
    if (result) {
        @synchronized(mixRegularLock) { mixRegularPlayerList = result; }
        atomic_fetch_add_explicit(&mixRegularListResults, 1, memory_order_relaxed);
        mixRegularRecordObject(result, YES);
    }
    return result;
}
static id mixRegularObserveProvideQueue(id self, SEL sel) {
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { mixRegularPlayerService = self; }
    id result = mixOriginalProvideQueue(self, sel);
    if (result) @synchronized(mixRegularLock) { mixRegularPlayerQueue = result; }
    return result;
}
static void mixRegularObserveInjection(id self, SEL sel, id provider) {
    mixOriginalRegularInjection(self, sel, provider);
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { mixRegularPlayerService = self; }
    atomic_fetch_add_explicit(&mixRegularPlayerInjectionCalls, 1, memory_order_relaxed);
}

// Validate exact Objective-C ABIs from Spotify 9.2.2's runtime before
// installing the wrappers. A missing class returns -1 for a later retry.
int MixRebuildInstallRegularPlayerObserver(void) {
    int installed = atomic_load_explicit(&mixRegularPlayerInstall, memory_order_acquire);
    if (installed != -100) return installed;
    Class cls = objc_getClass("Player_CommonImpl.SPTPlayerServiceImplementation");
    if (!cls) return -1;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    int mask = 0;
    for (unsigned int i = 0; i < count; ++i) {
        Method method = methods[i];
        SEL sel = method_getName(method);
        const char *type = method_getTypeEncoding(method);
        if (!sel || !type) continue;
        const char *name = sel_getName(sel);
        if (!mixOriginalProvidePlayer &&
            strcmp(name, "providePlayerWithViewURI:featureIdentifier:referrerIdentifier:queue:") == 0 &&
            strcmp(type, "@48@0:8@16@24@32@40") == 0) {
            mixOriginalProvidePlayer = (id (*)(id, SEL, id, id, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)mixRegularObserveProvidePlayer);
            mask |= 1;
        } else if (!mixOriginalProvideList &&
            strcmp(name, "providePlayerListWithViewURI:featureIdentifier:referrerIdentifier:queue:") == 0 &&
            strcmp(type, "@48@0:8@16@24@32@40") == 0) {
            mixOriginalProvideList = (id (*)(id, SEL, id, id, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)mixRegularObserveProvideList);
            mask |= 2;
        } else if (!mixOriginalRegularInjection &&
            strcmp(name, "_injectDependenciesWithProvider:") == 0 &&
            strcmp(type, "v24@0:8@16") == 0) {
            mixOriginalRegularInjection = (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)mixRegularObserveInjection);
            mask |= 4;
        }
        else if (!mixOriginalProvideQueue &&
            strcmp(name, "providePlayerQueue") == 0 &&
            strcmp(type, "@16@0:8") == 0) {
            mixOriginalProvideQueue = (id (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)mixRegularObserveProvideQueue);
            mask |= 8;
        }
    }
    if (methods) free(methods);
    if (!mask) return -2;
    mixRegularEnsureStore();
    atomic_store_explicit(&mixRegularPlayerInstall, mask, memory_order_release);
    return mask;
}
NSString *MixRebuildRegularPlayerStatus(void) {
    unsigned livePlayers = 0, liveLists = 0;
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) {
        livePlayers = (unsigned)mixRegularLivePlayers.count;
        liveLists = (unsigned)mixRegularLiveLists.count;
    }
    return [NSString stringWithFormat:
        @"native service observer bitmask=%d (1=player,2=list,4=injection,8=queue); "
        @"dependency injections=%u; player requests=%u success=%u; "
        @"player-list requests=%u success=%u; "
        @"currently live returned player proxies=%u; currently live player lists=%u; "
        @"not proof of two decoded tracks",
        atomic_load_explicit(&mixRegularPlayerInstall, memory_order_acquire),
        atomic_load_explicit(&mixRegularPlayerInjectionCalls, memory_order_relaxed),
        atomic_load_explicit(&mixRegularPlayerRequests, memory_order_relaxed),
        atomic_load_explicit(&mixRegularPlayerResults, memory_order_relaxed),
        atomic_load_explicit(&mixRegularListRequests, memory_order_relaxed),
        atomic_load_explicit(&mixRegularListResults, memory_order_relaxed),
        livePlayers, liveLists];
}


id MixRebuildRegularPlayerService(void) {
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { return mixRegularPlayerService; }
}
id MixRebuildRegularPlayerQueue(void) {
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { if (mixRegularPlayerQueue) return mixRegularPlayerQueue; }
    id service = MixRebuildRegularPlayerService();
    if (!service) return nil;
    SEL sel = NSSelectorFromString(@"providePlayerQueue");
    Method method = class_getInstanceMethod(object_getClass(service), sel);
    const char *type = method ? method_getTypeEncoding(method) : NULL;
    if (!type || strcmp(type, "@16@0:8") != 0) return nil;
    id queue = ((id (*)(id, SEL))objc_msgSend)(service, sel);
    if (queue) @synchronized(mixRegularLock) { mixRegularPlayerQueue = queue; }
    return queue;
}
id MixRebuildRegularPlayerList(void) {
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { return mixRegularPlayerList; }
}
id MixRebuildRegularLastPlayer(void) {
    mixRegularEnsureStore();
    @synchronized(mixRegularLock) { return mixRegularLastPlayer; }
}

static Method MixRebuildVerifiedMethod(id target, NSString *selectorName, const char *encoding) {
    if (!target) return NULL;
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(object_getClass(target), sel);
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && strcmp(actual, encoding) == 0 ? method : NULL;
}
static id MixRebuildObjectGetter(id target, NSString *selectorName) {
    Method method = MixRebuildVerifiedMethod(target, selectorName, "@16@0:8");
    if (!method) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, method_getName(method));
}
id MixRebuildCreateSecondaryPlayer(id service, id viewURI, id featureIdentifier,
                                   id referrerIdentifier, id queue) {
    Method method = MixRebuildVerifiedMethod(service,
        @"providePlayerWithViewURI:featureIdentifier:referrerIdentifier:queue:",
        "@48@0:8@16@24@32@40");
    if (!method) return nil;
    id player = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        service, method_getName(method), viewURI, featureIdentifier, referrerIdentifier, queue);
    if (player) {
        mixRegularEnsureStore();
        @synchronized(mixRegularLock) { mixRegularLastPlayer = player; }
    }
    return player;
}
id MixRebuildCreatePlayerContext(id trackURI) {
    Class cls = objc_getClass("SPTPlayerContext");
    if (!cls || !trackURI) return nil;
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
    SEL initSel = NSSelectorFromString(@"initWithDictionary:");
    Method method = class_getInstanceMethod(cls, initSel);
    const char *type = method ? method_getTypeEncoding(method) : NULL;
    if (!type || strcmp(type, "@24@0:8@16") != 0) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(allocated, initSel, @{@"uri": trackURI});
}
id MixRebuildCreatePlayOptions(BOOL initiallyPaused, double playbackSpeed, double seekToMs) {
    Class cls = objc_getClass("SPTPlayOptions");
    if (!cls) return nil;
    id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("alloc"));
    id options = ((id (*)(id, SEL))objc_msgSend)(allocated, sel_registerName("init"));
    if (!options) return nil;
    SEL pausedSel = NSSelectorFromString(@"setInitiallyPaused:");
    Method paused = class_getInstanceMethod(object_getClass(options), pausedSel);
    const char *pausedType = paused ? method_getTypeEncoding(paused) : NULL;
    if (pausedType && strcmp(pausedType, "v20@0:8B16") == 0)
        ((void (*)(id, SEL, BOOL))objc_msgSend)(options, pausedSel, initiallyPaused);
    if (isfinite(playbackSpeed) && playbackSpeed > 0.0 && fabs(playbackSpeed - 1.0) > 0.0001) {
        SEL speedSel = NSSelectorFromString(@"setPlaybackSpeed:");
        Method speed = class_getInstanceMethod(object_getClass(options), speedSel);
        const char *speedType = speed ? method_getTypeEncoding(speed) : NULL;
        if (speedType && strcmp(speedType, "v24@0:8@16") == 0)
            ((void (*)(id, SEL, id))objc_msgSend)(options, speedSel, @(playbackSpeed));
    }
    if (isfinite(seekToMs) && seekToMs >= 0.0) {
        SEL seekSel = NSSelectorFromString(@"setSeekTo:");
        Method seek = class_getInstanceMethod(object_getClass(options), seekSel);
        const char *seekType = seek ? method_getTypeEncoding(seek) : NULL;
        if (seekType && strcmp(seekType, "v24@0:8@16") == 0)
            ((void (*)(id, SEL, id))objc_msgSend)(options, seekSel, @(seekToMs));
    }
    return options;
}
BOOL MixRebuildPreparePlayer(id player, id context, id options, id viewURI) {
    Method method = MixRebuildVerifiedMethod(player, @"preparePlaybackOfContext:options:viewURI:",
                                             "@40@0:8@16@24@32");
    if (!method) return NO;
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        player, method_getName(method), context, options, viewURI);
    return result != nil;
}
BOOL MixRebuildPlayPlayer(id player, id context, id options, id viewURI) {
    Method method = MixRebuildVerifiedMethod(player, @"playContext:options:viewURI:",
                                              "@40@0:8@16@24@32");
    if (!method) return NO;
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        player, method_getName(method), context, options, viewURI);
    return result != nil;
}
BOOL MixRebuildStopPlayer(id player) {
    Method method = MixRebuildVerifiedMethod(player, @"stop", "v16@0:8");
    if (!method) return NO;
    ((void (*)(id, SEL))objc_msgSend)(player, method_getName(method));
    return YES;
}
id MixRebuildPlayerState(id player) { return MixRebuildObjectGetter(player, @"state"); }
id MixRebuildPlayerTrack(id player) {
    return MixRebuildObjectGetter(MixRebuildPlayerState(player), @"track");
}
id MixRebuildPlayerTrackURI(id player) {
    return MixRebuildObjectGetter(MixRebuildPlayerTrack(player), @"URI");
}
static double MixRebuildDoubleGetter(id target, NSString *selectorName) {
    Method method = MixRebuildVerifiedMethod(target, selectorName, "d16@0:8");
    if (!method) return -1.0;
    return ((double (*)(id, SEL))objc_msgSend)(target, method_getName(method));
}
double MixRebuildPlayerPositionMs(id player) {
    return MixRebuildDoubleGetter(MixRebuildPlayerState(player), @"position");
}
double MixRebuildPlayerDurationMs(id player) {
    return MixRebuildDoubleGetter(MixRebuildPlayerState(player), @"duration");
}
BOOL MixRebuildPlayerIsPlaying(id player) {
    id state = MixRebuildPlayerState(player);
    Method method = MixRebuildVerifiedMethod(state, @"isPlaying", "B16@0:8");
    return method ? ((BOOL (*)(id, SEL))objc_msgSend)(state, method_getName(method)) : NO;
}
id MixRebuildPlayerLogicalIdentifier(id player) {
    return MixRebuildObjectGetter(player, @"logicalPlaybackIdentifier");
}
id MixRebuildPlayerViewURI(id player) { return MixRebuildObjectGetter(player, @"viewURI"); }
id MixRebuildPlayerFeatureIdentifier(id player) { return MixRebuildObjectGetter(player, @"featureIdentifier"); }
id MixRebuildPlayerReferrerIdentifier(id player) { return MixRebuildObjectGetter(player, @"referrerIdentifier"); }
id MixRebuildQueueNextTrack(id queue) {
    id tracks = MixRebuildObjectGetter(queue, @"nextTracks");
    return [tracks isKindOfClass:NSArray.class] ? [tracks firstObject] : nil;
}
id MixRebuildQueueForNextTrack(id queue) {
    if (!queue) return nil;
    id nextTrack = MixRebuildQueueNextTrack(queue);
    if (!nextTrack) return nil;
    id copy = [queue conformsToProtocol:@protocol(NSCopying)] ? [queue copy] : nil;
    if (!copy) return nil;
    id currentTrack = MixRebuildObjectGetter(queue, @"track");
    NSArray *previous = MixRebuildObjectGetter(queue, @"prevTracks") ?: @[];
    NSArray *next = MixRebuildObjectGetter(queue, @"nextTracks") ?: @[];
    NSMutableArray *newPrevious = [NSMutableArray array];
    if (currentTrack) [newPrevious addObject:currentTrack];
    [newPrevious addObjectsFromArray:previous];
    NSArray *remaining = next.count > 1 ? [next subarrayWithRange:NSMakeRange(1, next.count - 1)] : @[];
    ((void (*)(id, SEL, id))objc_msgSend)(copy, NSSelectorFromString(@"setTrack:"), nextTrack);
    ((void (*)(id, SEL, id))objc_msgSend)(copy, NSSelectorFromString(@"setPrevTracks:"), newPrevious);
    ((void (*)(id, SEL, id))objc_msgSend)(copy, NSSelectorFromString(@"setNextTracks:"), remaining);
    return copy;
}
BOOL MixRebuildPromotePlayer(id playerList, id player) {
    if (!playerList || !player) return NO;
    id playerID = MixRebuildPlayerLogicalIdentifier(player);
    if (!playerID) return NO;
    id currentPlayers = MixRebuildObjectGetter(playerList, @"players");
    NSMutableArray *identifiers = [NSMutableArray array];
    if ([currentPlayers isKindOfClass:NSArray.class]) {
        for (id item in currentPlayers) {
            id identifier = MixRebuildPlayerLogicalIdentifier(item);
            if (identifier && ![identifiers containsObject:identifier]) [identifiers addObject:identifier];
        }
    }
    if (![identifiers containsObject:playerID]) [identifiers addObject:playerID];
    SEL sel = NSSelectorFromString(@"updateIdentifiers:frontIdentifier:localIdentifier:");
    Method method = MixRebuildVerifiedMethod(playerList, @"updateIdentifiers:frontIdentifier:localIdentifier:",
                                             "v40@0:8@16@24@32");
    if (!method) return NO;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(playerList, sel, identifiers, playerID, playerID);
    id front = MixRebuildObjectGetter(playerList, @"frontPlayer");
    id frontID = MixRebuildPlayerLogicalIdentifier(front);
    return [frontID isEqual:playerID];
}
void MixRebuildArmNextNativePCMSourceMuted(void) { SAPArmNextNativePCMSourceMuted(); }
void MixRebuildCancelNextNativePCMSourceMute(void) { SAPCancelNextNativePCMSourceMute(); }
uint32_t MixRebuildReadActiveNativePCMSourceIDs(uint32_t *ids, uint32_t capacity) {
    return SAPReadActiveNativePCMSourceIDs(ids, capacity);
}
void MixRebuildSetNativePCMSourceGain(uint32_t sourceID, float gain) {
    SAPSetNativePCMSourceGain(sourceID, gain);
}
void MixRebuildResetNativePCMSourceGains(void) { SAPResetNativePCMSourceGains(); }

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
