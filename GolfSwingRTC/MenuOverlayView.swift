import UIKit

protocol MenuOverlayDelegate: AnyObject {
    func menuDidSelectSettings()
    func menuDidSelectVideoLibrary()
    func menuDidClose()
}

/// Slide-up menu overlay with Settings and Video Library options
final class MenuOverlayView: UIView {

    weak var delegate: MenuOverlayDelegate?

    // MARK: - UI Elements

    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        view.layer.cornerRadius = 16
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Menu"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        button.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .secondaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let settingsButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: config), for: .normal)
        button.setTitle("  Settings", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        button.contentHorizontalAlignment = .leading
        button.tintColor = .label
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let libraryButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "photo.on.rectangle.angled", withConfiguration: config), for: .normal)
        button.setTitle("  Video Library", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        button.contentHorizontalAlignment = .leading
        button.tintColor = .label
        button.translatesAutoresizingMaskIntoConstraints = false
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
        backgroundColor = UIColor.black.withAlphaComponent(0.4)
        alpha = 0

        addSubview(containerView)

        // Container constraints - positioned at bottom
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 220)
        ])

        // Title and close button
        containerView.addSubview(titleLabel)
        containerView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16)
        ])

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        // Divider
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(divider)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        // Menu buttons stack
        let buttonStack = UIStackView(arrangedSubviews: [settingsButton, libraryButton])
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            buttonStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
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

    @objc private func closeTapped() {
        hide()
    }

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

        // Start with container off screen
        containerView.transform = CGAffineTransform(translationX: 0, y: 220)

        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            self.alpha = 1
            self.containerView.transform = .identity
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.alpha = 0
            self.containerView.transform = CGAffineTransform(translationX: 0, y: 220)
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
