import UIKit
import AVKit

final class SwingLibraryViewController: UIViewController {

    private var swings: [SavedSwing] = []

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .systemBackground
        cv.delegate = self
        cv.dataSource = self
        cv.register(SwingCell.self, forCellWithReuseIdentifier: SwingCell.reuseId)
        cv.translatesAutoresizingMaskIntoConstraints = false
        return cv
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "No saved swings yet.\nSwings are automatically saved after replay."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 16)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
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

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Video Library"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let editButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Edit", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private var isEditMode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        loadSwings()
    }

    private func setupUI() {
        // Header
        let headerView = UIView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        headerView.addSubview(closeButton)
        headerView.addSubview(titleLabel)
        headerView.addSubview(editButton)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 50),

            closeButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            editButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            editButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor)
        ])

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)

        // Collection view
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Empty state
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40)
        ])
    }

    private func loadSwings() {
        swings = SwingStorage.shared.loadSwingsList()
        emptyLabel.isHidden = !swings.isEmpty
        editButton.isHidden = swings.isEmpty
        collectionView.reloadData()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func editTapped() {
        isEditMode.toggle()
        editButton.setTitle(isEditMode ? "Done" : "Edit", for: .normal)
        collectionView.reloadData()
    }

    private func deleteSwing(at indexPath: IndexPath) {
        let swing = swings[indexPath.item]

        let alert = UIAlertController(
            title: "Delete Swing?",
            message: "This will permanently remove this recording.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            SwingStorage.shared.deleteSwing(swing)
            self?.swings.remove(at: indexPath.item)
            self?.collectionView.deleteItems(at: [indexPath])
            self?.updateEmptyState()
        })
        present(alert, animated: true)
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !swings.isEmpty
        editButton.isHidden = swings.isEmpty
        if swings.isEmpty {
            isEditMode = false
            editButton.setTitle("Edit", for: .normal)
        }
    }

    private func playSwing(_ swing: SavedSwing) {
        guard let remoteURL = SwingStorage.shared.getVideoURL(for: swing, front: false) else { return }

        let frontURL = SwingStorage.shared.getVideoURL(for: swing, front: true)

        if let frontURL = frontURL {
            // Show dual player
            let dualVC = DualVideoPlayerViewController(remoteURL: remoteURL, frontURL: frontURL)
            dualVC.modalPresentationStyle = .fullScreen
            present(dualVC, animated: true)
        } else {
            // Single video - use standard player
            let player = AVPlayer(url: remoteURL)
            let playerVC = AVPlayerViewController()
            playerVC.player = player
            present(playerVC, animated: true) {
                player.play()
            }
        }
    }
}

// MARK: - UICollectionViewDataSource

extension SwingLibraryViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        swings.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SwingCell.reuseId, for: indexPath) as! SwingCell
        let swing = swings[indexPath.item]
        cell.configure(with: swing, isEditMode: isEditMode)
        cell.onDelete = { [weak self] in
            self?.deleteSwing(at: indexPath)
        }
        return cell
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension SwingLibraryViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let spacing: CGFloat = 8
        let insets: CGFloat = 16
        let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 4 : 2
        let totalSpacing = insets + (spacing * (columns - 1))
        let width = (collectionView.bounds.width - totalSpacing) / columns
        return CGSize(width: width, height: width + 30) // Extra space for date label
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditMode else { return }
        let swing = swings[indexPath.item]
        playSwing(swing)
    }
}

// MARK: - SwingCell

private final class SwingCell: UICollectionViewCell {
    static let reuseId = "SwingCell"

    var onDelete: (() -> Void)?

    private let thumbnailView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .systemGray5
        iv.layer.cornerRadius = 8
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let dateLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let deleteButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        button.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .systemRed
        button.backgroundColor = .white
        button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private let playIcon: UIImageView = {
        let iv = UIImageView()
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        iv.image = UIImage(systemName: "play.circle.fill", withConfiguration: config)
        iv.tintColor = .white
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCell() {
        contentView.addSubview(thumbnailView)
        contentView.addSubview(dateLabel)
        contentView.addSubview(deleteButton)
        thumbnailView.addSubview(playIcon)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnailView.heightAnchor.constraint(equalTo: thumbnailView.widthAnchor),

            dateLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            dateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            deleteButton.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 4),
            deleteButton.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -4),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24),

            playIcon.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor)
        ])

        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
    }

    func configure(with swing: SavedSwing, isEditMode: Bool) {
        thumbnailView.image = SwingStorage.shared.getThumbnail(for: swing)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        dateLabel.text = formatter.string(from: swing.date)

        deleteButton.isHidden = !isEditMode
        playIcon.isHidden = isEditMode
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}

// MARK: - DualVideoPlayerViewController

final class DualVideoPlayerViewController: UIViewController {

    private let remoteURL: URL
    private let frontURL: URL

    private var remotePlayer: AVPlayer?
    private var frontPlayer: AVPlayer?

    private let remotePlayerView = PlayerView()
    private let frontPlayerView = PlayerView()

    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        button.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        button.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    init(remoteURL: URL, frontURL: URL) {
        self.remoteURL = remoteURL
        self.frontURL = frontURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupPlayers()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        remotePlayer?.pause()
        frontPlayer?.pause()
    }

    private func setupUI() {
        let stack = UIStackView(arrangedSubviews: [frontPlayerView, remotePlayerView])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(closeButton)
        view.addSubview(playPauseButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 50),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
    }

    private func setupPlayers() {
        remotePlayer = AVPlayer(url: remoteURL)
        frontPlayer = AVPlayer(url: frontURL)

        remotePlayerView.player = remotePlayer
        frontPlayerView.player = frontPlayer

        // Loop playback
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: remotePlayer?.currentItem
        )
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func playPauseTapped() {
        guard let remote = remotePlayer, let front = frontPlayer else { return }

        if remote.rate == 0 {
            remote.play()
            front.play()
            let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
            playPauseButton.setImage(UIImage(systemName: "pause.circle.fill", withConfiguration: config), for: .normal)
        } else {
            remote.pause()
            front.pause()
            let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
            playPauseButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: config), for: .normal)
        }
    }

    @objc private func playerDidFinish() {
        remotePlayer?.seek(to: .zero)
        frontPlayer?.seek(to: .zero)
        remotePlayer?.play()
        frontPlayer?.play()
    }
}

// MARK: - PlayerView

private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set {
            (layer as? AVPlayerLayer)?.player = newValue
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        }
    }
}
