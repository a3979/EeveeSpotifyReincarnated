import UIKit
import Orion
import ObjectiveC.runtime

/// Installed only for playlist screens in Spotify's own navigation hierarchy.
struct MixPlaylistFallbackGroup: HookGroup {}

private var playlistMixButtonKey: UInt8 = 0

final class MixPlaylistButton: UIButton {
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Eevee.Playlist.Mix"
        accessibilityHint = "Tap to toggle local playlist Mix. Hold to edit transitions."
        titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        layer.cornerRadius = 18
        contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        imageEdgeInsets.right = 5
        addTarget(self, action: #selector(toggle), for: .touchUpInside)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(edit(_:))))
        observer = NotificationCenter.default.addObserver(forName: .mixPlaylistStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let active = MixPlaylistRuntime.enabled
        setTitle("Mix", for: .normal)
        setTitleColor(.white, for: .normal)
        tintColor = .white
        backgroundColor = UIColor(white: 0.16, alpha: 1)
        layer.borderWidth = active ? 1.5 : 1
        layer.borderColor = active ? UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 1).cgColor
                                    : UIColor(white: 0.65, alpha: 0.45).cgColor
        accessibilityLabel = active ? "Local playlist Mix on" : "Local playlist Mix off"
        accessibilityValue = active ? "On" : "Off"
    }

    @objc private func toggle() {
        MixPlaylistRuntime.enable(!MixPlaylistRuntime.enabled)
        refresh()
    }

    @objc private func edit(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        MixPlaylistSurface.presentEditor(from: self)
    }
}

enum MixPlaylistSurface {
    static func installFallback(in root: UIView) {
        guard root.bounds.width > 220, root.bounds.height > 180 else { return }
        if let existing = objc_getAssociatedObject(root, &playlistMixButtonKey) as? MixPlaylistButton {
            existing.refresh()
            return
        }
        let button = MixPlaylistButton(frame: .zero)
        objc_setAssociatedObject(root, &playlistMixButtonKey, button, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        root.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 54),
            button.widthAnchor.constraint(equalToConstant: 90),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    static func presentEditor(from source: UIView) {
        var cursor: UIResponder? = source
        while let current = cursor {
            if let vc = current as? UIViewController {
                let editor = MixPlaylistEditorController()
                let nav = UINavigationController(rootViewController: editor)
                nav.modalPresentationStyle = .pageSheet
                if #available(iOS 15.0, *) {
                    nav.sheetPresentationController?.detents = [.medium(), .large()]
                }
                vc.present(nav, animated: true)
                return
            }
            cursor = current.next
        }
    }
}

private final class MixPlaylistEditorController: UIViewController {
    private let mode = UISwitch()
    private let slider = UISlider()
    private let secondsLabel = UILabel()
    private let status = UILabel()
    private var refreshTimer: Timer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Mix"
        view.backgroundColor = UIColor(red: 0.075, green: 0.075, blue: 0.075, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22)
        ])
        func makeLabel(_ value: String, size: CGFloat, muted: Bool = false) -> UILabel {
            let label = UILabel()
            label.text = value
            label.textColor = muted ? .lightGray : .white
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: size, weight: size > 17 ? .semibold : .regular)
            return label
        }

        stack.addArrangedSubview(makeLabel("Mix your playlist", size: 25))
        stack.addArrangedSubview(makeLabel("Use your usual Spotify playlists and controls. This local mode does not open the Premium Mix editor.", size: 13, muted: true))

        let toggleRow = UIStackView()
        toggleRow.axis = .horizontal
        toggleRow.alignment = .center
        toggleRow.addArrangedSubview(makeLabel("Mix", size: 17))
        toggleRow.addArrangedSubview(UIView())
        mode.isOn = MixPlaylistRuntime.enabled
        mode.onTintColor = UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 1)
        mode.addTarget(self, action: #selector(toggle), for: .valueChanged)
        toggleRow.addArrangedSubview(mode)
        stack.addArrangedSubview(toggleRow)

        secondsLabel.textColor = .white
        secondsLabel.font = .systemFont(ofSize: 16, weight: .medium)
        stack.addArrangedSubview(secondsLabel)
        slider.minimumValue = 2
        slider.maximumValue = 12
        slider.value = Float(MixPlaylistRuntime.seconds)
        slider.minimumTrackTintColor = UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 1)
        slider.addTarget(self, action: #selector(durationChanged), for: .valueChanged)
        stack.addArrangedSubview(slider)

        status.textColor = .lightGray
        status.numberOfLines = 0
        status.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(status)

        let copy = UIButton(type: .system)
        copy.setTitle("Copy playback diagnostics", for: .normal)
        copy.contentHorizontalAlignment = .left
        copy.tintColor = UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 1)
        copy.addTarget(self, action: #selector(copyDiagnostics), for: .touchUpInside)
        stack.addArrangedSubview(copy)

        refresh()
    }

    private func refresh() {
        mode.isOn = MixPlaylistRuntime.enabled
        secondsLabel.text = "Transition duration · \(MixPlaylistRuntime.seconds) sec"
        status.text = MixPlaylistRuntime.nativeStatus + "\nA native preference change does not prove two streamed tracks overlap."
    }

    @objc private func toggle() {
        MixPlaylistRuntime.enable(mode.isOn)
        refresh()
    }

    @objc private func durationChanged() {
        MixPlaylistRuntime.setSeconds(Int(slider.value.rounded()))
        refresh()
    }

    @objc private func copyDiagnostics() {
        UIPasteboard.general.string = MixPlaylistRuntime.diagnostics()
    }

    @objc private func close() { dismiss(animated: true) }
}


// Intercept touches on Spotify's own Mix pill rather than painting a second
// playlist button. The previous touchUpInside target could be cancelled by
// Spotify's SwiftUI/scroll touch routing. Long-press already worked because it
// used a recognizer. Give taps the same reliable gesture delivery, and reflect
// *local switch state* visually instead of leaving the native pill unchanged.
// This is a UI state indicator, NOT a claim that audio mixing is happening.
private final class SpotifyMixTouchInterceptor: UIButton {
    private var stateObserver: NSObjectProtocol?
    private let stateDot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "Eevee.Playlist.NativeMixInterceptor"
        accessibilityHint = "Tap to toggle local Mix. Hold to adjust transition settings."
        isAccessibilityElement = true

        stateDot.isUserInteractionEnabled = false
        stateDot.backgroundColor = UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 1)
        stateDot.layer.cornerRadius = 3
        addSubview(stateDot)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(edit(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.cancelsTouchesInView = true
        addGestureRecognizer(longPress)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = true
        tap.require(toFail: longPress)
        addGestureRecognizer(tap)

        stateObserver = NotificationCenter.default.addObserver(
            forName: .mixPlaylistStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(20, bounds.height / 2)
        stateDot.frame = CGRect(x: max(2, bounds.width - 12), y: 5, width: 6, height: 6)
    }

    func refresh() {
        let on = MixPlaylistRuntime.enabled
        backgroundColor = on
            ? UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 0.16)
            : .clear
        layer.borderWidth = on ? 1.5 : 0
        layer.borderColor = UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 1).cgColor
        stateDot.isHidden = !on
        accessibilityLabel = on ? "Local Mix enabled" : "Local Mix disabled"
        accessibilityValue = on ? "On" : "Off"
    }

    @objc private func toggle(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let requested = !MixPlaylistRuntime.enabled
        MixPlaylistRuntime.enable(requested)
        SpotifyNativeMixBinder.noteTap(result: MixPlaylistRuntime.enabled)
        refresh()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func edit(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        SpotifyNativeMixBinder.noteLongPress()
        MixPlaylistSurface.presentEditor(from: self)
    }
}

 enum SpotifyNativeMixBinder {
     private static weak var boundRoot: UIView?
     private static weak var boundPill: UIView?
     private static weak var interceptor: SpotifyMixTouchInterceptor?
     private static var lastScan: CFAbsoluteTime = 0
     private(set) static var scans = 0
     private(set) static var binds = 0
     private(set) static var tapEvents = 0
     private(set) static var longPressEvents = 0
     private(set) static var lastTapEnabled: Bool?

     static func noteTap(result: Bool) {
         tapEvents += 1
         lastTapEnabled = result
         eeveeLog("[MixNative] Spotify pill tapped; local enabled=\(result), taps=\(tapEvents)")
     }

     static func noteLongPress() {
         longPressEvents += 1
     }

     static var attached: Bool {
         guard let root = boundRoot, let pill = boundPill, let overlay = interceptor else { return false }
         return root.window != nil && pill.window != nil && !pill.isHidden &&
                pill.alpha > 0.05 && pill.isDescendant(of: root) && overlay.superview === pill
     }

     static func install(in root: UIView) {
         guard root.window != nil else { return }
         if attached && boundRoot === root {
             if let overlay = interceptor, let pill = boundPill {
                 overlay.frame = pill.bounds
                 overlay.refresh()
                 pill.bringSubviewToFront(overlay)
             }
             return
         }
         let now = CFAbsoluteTimeGetCurrent()
         guard now - lastScan >= 0.5 else { return }
         lastScan = now
         scans += 1
         guard let pill = findNativePill(in: root) else { return }
         interceptor?.removeFromSuperview()
         let overlay = SpotifyMixTouchInterceptor(frame: pill.bounds)
         overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
         pill.addSubview(overlay)
         pill.bringSubviewToFront(overlay)
         boundRoot = root
         boundPill = pill
         interceptor = overlay
         binds += 1
         eeveeLog("[MixNative] Bound original Spotify playlist Mix pill")
     }

     private static func findNativePill(in root: UIView) -> UIView? {
         var queue: [UIView] = [root]
         var offset = 0
         var visited = 0
         while offset < queue.count && visited < 1600 {
             let view = queue[offset]
             offset += 1
             visited += 1
             if view.isHidden || view.alpha < 0.03 { continue }
             if view is SpotifyMixTouchInterceptor || view is MixPlaylistButton { continue }
             if view.accessibilityIdentifier?.hasPrefix("Eevee.Playlist.") == true { continue }
             let text = (view as? UILabel)?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                 ?? (view as? UIButton)?.currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                 ?? view.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
             if let text, ["mix", "mix playlist", "mix this playlist"].contains(text.lowercased()) {
                 if let pill = nearestPill(for: view, inside: root) { return pill }
             }
             // The native Mix can be hosted by SwiftUI; scan its view
             // hierarchy without asking Spotify for Premium entitlements.
             queue.append(contentsOf: view.subviews)
         }
         return nil
     }

     private static func nearestPill(for label: UIView, inside root: UIView) -> UIView? {
         var node: UIView? = label
         var steps = 0
         var best: UIView?
         while let view = node, view !== root, steps < 9 {
             defer { node = view.superview; steps += 1 }
             let frame = view.bounds
             let w = frame.width, h = frame.height
             guard view.isUserInteractionEnabled,
                   w >= 58, w <= 180, h >= 30, h <= 72,
                   view.window != nil else { continue }
             if view.accessibilityIdentifier?.hasPrefix("Eevee.") == true { continue }
             // Prefer a real button/control or a pill-sized hosting wrapper
             // rather than a text label. Do not cover entire action toolbars.
             if view is UIControl { return view }
             best = view
         }
         return best
     }
 }

class MixPlaylistFallbackHook: ClassHook<UIViewController> {
    typealias Group = MixPlaylistFallbackGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl17FTPViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let root = target.viewIfLoaded { SpotifyNativeMixBinder.install(in: root) }
    }
}
