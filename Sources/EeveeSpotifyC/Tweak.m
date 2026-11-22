#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
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

// The Swift preferences class takes a primitive integer; NSObject.perform
// would pass an object and corrupt the arguments. Invoke the verified selector
// with the exact integer ABI, exclusively from the main thread.
void EeveeLocalMixSetNativeCrossfadeTime(id target, NSInteger seconds) {
    SEL selector = NSSelectorFromString(@"setAudioCrossfadeTime:");
    if (!target || ![target respondsToSelector:selector]) return;
    typedef void (*SetCrossfade)(id, SEL, NSInteger);
    ((SetCrossfade)objc_msgSend)(target, selector, seconds);
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
