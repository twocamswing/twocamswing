import UIKit

protocol MenuOverlayDelegate: AnyObject {
    func menuDidSelectSettings()
    func menuDidSelectVideoLibrary()
    func menuDidClose()
}

/// Compact floating menu with icon buttons, anchored at bottom right near burger button
final class MenuOverlayView: UIView {

    weak var delegate: MenuOverlayDelegate?

    // MARK: - UI Elements

    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        view.layer.cornerRadius = 12
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.3
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.layer.shadowRadius = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let settingsButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        button.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Settings"
        return button
    }()

    private let libraryButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        button.setImage(UIImage(systemName: "photo.on.rectangle.angled", withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Video Library"
        button.accessibilityIdentifier = "libraryButton"
        return button
    }()


    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupView() {
        backgroundColor = UIColor.black.withAlphaComponent(0.3)
        alpha = 0

        addSubview(containerView)

        // Container positioned at bottom right
        NSLayoutConstraint.activate([
            containerView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            containerView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -70)
        ])

        // Vertical stack of icon buttons - easier to reach from edge
        let buttonStack = UIStackView(arrangedSubviews: [libraryButton, settingsButton])
        buttonStack.axis = .vertical
        buttonStack.spacing = 12
        buttonStack.alignment = .center
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            buttonStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),
            buttonStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),
            libraryButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        libraryButton.addTarget(self, action: #selector(libraryTapped), for: .touchUpInside)

        // Tap outside to close
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)
    }

    // MARK: - Actions

    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        if !containerView.frame.contains(location) {
            hide()
        }
    }

    @objc private func settingsTapped() {
        hide { [weak self] in
            self?.delegate?.menuDidSelectSettings()
        }
    }

    @objc private func libraryTapped() {
        hide { [weak self] in
            self?.delegate?.menuDidSelectVideoLibrary()
        }
    }

    // MARK: - Show/Hide

    func show(in parentView: UIView) {
        frame = parentView.bounds
        parentView.addSubview(self)

        // Start with container scaled down and faded
        containerView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        containerView.alpha = 0

        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
            self.containerView.transform = .identity
            self.containerView.alpha = 1
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseIn) {
            self.alpha = 0
            self.containerView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            self.containerView.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            self.delegate?.menuDidClose()
            completion?()
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension MenuOverlayView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Only handle taps outside the container
        let location = touch.location(in: self)
        return !containerView.frame.contains(location)
    }
}
