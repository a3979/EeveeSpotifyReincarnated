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

func activateMixNativeServiceProbe() {
    guard let cls = NSClassFromString(MixNativeServiceHook.targetName) else {
        eeveeLog("[MixNative] Player service class absent")
        return
    }
    let selector = NSSelectorFromString("_injectDependenciesWithProvider:")
    guard let method = class_getInstanceMethod(cls, selector),
          let encoding = method_getTypeEncoding(method),
          String(cString: encoding).hasPrefix("v24@0:8@16") else {
        eeveeLog("[MixNative] Player service selector/signature changed; skipping")
        return
    }
    MixNativeServiceProbeGroup().activate()
    eeveeLog("[MixNative] Read-only native mixing player lifecycle probe armed")
}
