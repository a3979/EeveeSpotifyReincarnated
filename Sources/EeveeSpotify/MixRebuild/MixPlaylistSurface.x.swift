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
        setImage(UIImage(systemName: "waveform.path"), for: .normal)
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
        setTitle(active ? "Mix On" : "Mix", for: .normal)
        setTitleColor(active ? .black : .white, for: .normal)
        tintColor = active ? .black : .white
        backgroundColor = active ? UIColor(red: 0.12, green: 0.84, blue: 0.39, alpha: 1)
                                 : UIColor(white: 0.22, alpha: 1)
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

class MixPlaylistFallbackHook: ClassHook<UIViewController> {
    typealias Group = MixPlaylistFallbackGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl17FTPViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        if let root = target.viewIfLoaded { MixPlaylistSurface.installFallback(in: root) }
    }
}
