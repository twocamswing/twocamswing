import UIKit

protocol SettingsOverlayDelegate: AnyObject {
    func settingsDidChange()
    func settingsDidClose()
}

/// Overlay view for app settings, slides up from bottom
final class SettingsOverlayView: UIView {

    weak var delegate: SettingsOverlayDelegate?

    // MARK: - Settings Keys
    private let replayRepeatCountKey = "receiver.replayRepeatCount"

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
        label.text = "Settings"
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

    private let repeatCountLabel: UILabel = {
        let label = UILabel()
        label.text = "Replay Repeats"
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let repeatCountStepper: UIStepper = {
        let stepper = UIStepper()
        stepper.minimumValue = 1
        stepper.maximumValue = 5
        stepper.stepValue = 1
        stepper.value = 1
        stepper.translatesAutoresizingMaskIntoConstraints = false
        return stepper
    }()

    private let repeatCountValueLabel: UILabel = {
        let label = UILabel()
        label.text = "1"
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return label
    }()

    private let repeatDescriptionLabel: UILabel = {
        let label = UILabel()
        label.text = "Number of times to play slow-motion replay"
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
        loadSettings()
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

        // Replay repeat count row
        let repeatRow = UIStackView(arrangedSubviews: [repeatCountLabel, repeatCountValueLabel, repeatCountStepper])
        repeatRow.axis = .horizontal
        repeatRow.spacing = 12
        repeatRow.alignment = .center
        repeatRow.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(repeatRow)

        NSLayoutConstraint.activate([
            repeatRow.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 20),
            repeatRow.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            repeatRow.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20)
        ])

        containerView.addSubview(repeatDescriptionLabel)
        NSLayoutConstraint.activate([
            repeatDescriptionLabel.topAnchor.constraint(equalTo: repeatRow.bottomAnchor, constant: 6),
            repeatDescriptionLabel.leadingAnchor.constraint(equalTo: repeatRow.leadingAnchor)
        ])

        repeatCountStepper.addTarget(self, action: #selector(repeatCountChanged), for: .valueChanged)

        // Tap outside to close
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)
    }

    private func loadSettings() {
        let savedCount = UserDefaults.standard.integer(forKey: replayRepeatCountKey)
        let count = savedCount > 0 ? savedCount : 1
        repeatCountStepper.value = Double(count)
        repeatCountValueLabel.text = "\(count)"
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

    @objc private func repeatCountChanged() {
        let count = Int(repeatCountStepper.value)
        repeatCountValueLabel.text = "\(count)"
        UserDefaults.standard.set(count, forKey: replayRepeatCountKey)
        delegate?.settingsDidChange()
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

    func hide() {
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.alpha = 0
            self.containerView.transform = CGAffineTransform(translationX: 0, y: 220)
        } completion: { _ in
            self.removeFromSuperview()
            self.delegate?.settingsDidClose()
        }
    }

    // MARK: - Public Accessors

    static var replayRepeatCount: Int {
        let count = UserDefaults.standard.integer(forKey: "receiver.replayRepeatCount")
        return count > 0 ? count : 1
    }
}

// MARK: - UIGestureRecognizerDelegate

extension SettingsOverlayView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Only handle taps outside the container
        let location = touch.location(in: self)
        return !containerView.frame.contains(location)
    }
}
