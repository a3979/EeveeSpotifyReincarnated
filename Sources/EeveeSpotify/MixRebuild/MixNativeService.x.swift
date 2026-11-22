import Foundation
import Orion
import ObjectiveC.runtime

// Read-only lifecycle observation of the *actual* Spotify 9.2.2 service.
// Verified in the app's Mach-O: the selector has ObjC signature v24@0:8@16.
// The native transition player itself does not publish an ObjC play/mix API.
// Never guess or invoke Swift functions by address or bypass permission checks.
enum MixNativeServiceProbe {
    private(set) static var injections = 0
    private(set) static var observed = false
    private(set) static var hookInstalled = false
    fileprivate(set) static var discoveryAttempts = 0

    static func markHookInstalled() {
        hookInstalled = true
    }

    static func noteInjection() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { noteInjection() }
            return
        }
        observed = true
        injections += 1
    }
}

struct MixNativeServiceProbeGroup: HookGroup {}

class MixNativeServiceHook: ClassHook<NSObject> {
    typealias Group = MixNativeServiceProbeGroup
    static let targetName =
        "_TtC35PlaylistMixing_TransitionPlayerImpl33MixingTransitionPlayerServiceImpl"

    func _injectDependenciesWithProvider(_ provider: NSObject) {
        orig._injectDependenciesWithProvider(provider)
        MixNativeServiceProbe.noteInjection()
    }
}

// As with the preference class, the native playlist service can be registered
// after Eevee's tweak initializer. Retry instead of silently giving up.
private enum MixNativeServiceLateInstaller {
    private static var timer: Timer?
    private static var installed = false

    static func start() {
        guard !installed, timer == nil else { return }
        let begin = {
            guard !installed, timer == nil else { return }
            let poll = Timer(timeInterval: 0.25, repeats: true) { current in
                MixNativeServiceProbe.discoveryAttempts += 1
                guard let cls = NSClassFromString(MixNativeServiceHook.targetName) else {
                    if MixNativeServiceProbe.discoveryAttempts >= 240 {
                        current.invalidate()
                        timer = nil
                        eeveeLog("[MixNative] Player service class not registered within 60s")
                    }
                    return
                }
                let selector = NSSelectorFromString("_injectDependenciesWithProvider:")
                guard let method = class_getInstanceMethod(cls, selector),
                      let encoding = method_getTypeEncoding(method),
                      String(cString: encoding).hasPrefix("v24@0:8@16") else {
                    if MixNativeServiceProbe.discoveryAttempts >= 240 {
                        current.invalidate()
                        timer = nil
                        eeveeLog("[MixNative] Player service selector/ABI unavailable after 60s")
                    }
                    return
                }
                current.invalidate()
                timer = nil
                MixNativeServiceProbeGroup().activate()
                MixNativeServiceProbe.markHookInstalled()
                installed = true
                eeveeLog("[MixNative] Read-only service observer attached after \(MixNativeServiceProbe.discoveryAttempts) discovery checks")
            }
            timer = poll
            RunLoop.main.add(poll, forMode: .common)
            poll.fire()
        }
        if Thread.isMainThread {
            begin()
        } else {
            DispatchQueue.main.async(execute: begin)
        }
    }
}

func activateMixNativeServiceProbe() {
    MixNativeServiceLateInstaller.start()
}
