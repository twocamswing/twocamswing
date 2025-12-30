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
        cv.accessibilityIdentifier = "swingLibraryCollection"
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
        button.accessibilityIdentifier = "editButton"
        return button
    }()

    private var isEditMode = false
    private var selectedIndices: Set<Int> = []

    private let deleteSelectedButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Delete Selected", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        button.setTitleColor(.systemRed, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.accessibilityIdentifier = "deleteSelectedButton"
        return button
    }()

    private let selectAllButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Select All", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.accessibilityIdentifier = "selectAllButton"
        return button
    }()

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

        // Bottom toolbar for bulk actions
        let toolbarView = UIView()
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.backgroundColor = .systemBackground
        view.addSubview(toolbarView)

        toolbarView.addSubview(selectAllButton)
        toolbarView.addSubview(deleteSelectedButton)

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 50),

            selectAllButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 16),
            selectAllButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            deleteSelectedButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -16),
            deleteSelectedButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
        ])

        selectAllButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)
        deleteSelectedButton.addTarget(self, action: #selector(deleteSelectedTapped), for: .touchUpInside)

        // Collection view
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: toolbarView.topAnchor)
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

        // Show/hide toolbar buttons
        selectAllButton.isHidden = !isEditMode
        deleteSelectedButton.isHidden = !isEditMode

        // Clear selection when exiting edit mode
        if !isEditMode {
            selectedIndices.removeAll()
        }

        updateDeleteButtonState()
        collectionView.reloadData()
    }

    @objc private func selectAllTapped() {
        if selectedIndices.count == swings.count {
            // Deselect all
            selectedIndices.removeAll()
            selectAllButton.setTitle("Select All", for: .normal)
        } else {
            // Select all
            selectedIndices = Set(0..<swings.count)
            selectAllButton.setTitle("Deselect All", for: .normal)
        }
        updateDeleteButtonState()
        collectionView.reloadData()
    }

    @objc private func deleteSelectedTapped() {
        guard !selectedIndices.isEmpty else { return }

        let count = selectedIndices.count
        let alert = UIAlertController(
            title: "Delete \(count) Swing\(count > 1 ? "s" : "")?",
            message: "This will permanently remove \(count > 1 ? "these recordings" : "this recording").",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performBulkDelete()
        })
        present(alert, animated: true)
    }

    private func performBulkDelete() {
        // Delete in reverse order to maintain correct indices
        let sortedIndices = selectedIndices.sorted(by: >)
        for index in sortedIndices {
            let swing = swings[index]
            SwingStorage.shared.deleteSwing(swing)
            swings.remove(at: index)
        }

        selectedIndices.removeAll()
        collectionView.reloadData()
        updateEmptyState()
        updateDeleteButtonState()
    }

    private func updateDeleteButtonState() {
        let count = selectedIndices.count
        if count > 0 {
            deleteSelectedButton.setTitle("Delete (\(count))", for: .normal)
            deleteSelectedButton.isEnabled = true
        } else {
            deleteSelectedButton.setTitle("Delete Selected", for: .normal)
            deleteSelectedButton.isEnabled = false
        }
    }

    private func toggleSelection(at index: Int) {
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
        updateDeleteButtonState()

        // Update select all button text
        if selectedIndices.count == swings.count {
            selectAllButton.setTitle("Deselect All", for: .normal)
        } else {
            selectAllButton.setTitle("Select All", for: .normal)
        }
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
            // Show dual player with line data
            let dualVC = DualVideoPlayerViewController(
                remoteURL: remoteURL,
                frontURL: frontURL,
                remoteLine: swing.remoteLine,
                frontLine: swing.frontLine
            )
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
        let isSelected = selectedIndices.contains(indexPath.item)
        cell.configure(with: swing, isEditMode: isEditMode, isSelected: isSelected)
        cell.accessibilityIdentifier = "swingCell_\(indexPath.item)"
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
        if isEditMode {
            toggleSelection(at: indexPath.item)
            collectionView.reloadItems(at: [indexPath])
        } else {
            let swing = swings[indexPath.item]
            playSwing(swing)
        }
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

    private let selectionCheckmark: UIImageView = {
        let iv = UIImageView()
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        iv.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: config)
        iv.tintColor = .systemBlue
        iv.backgroundColor = .white
        iv.layer.cornerRadius = 12
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isHidden = true
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
        contentView.addSubview(selectionCheckmark)
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

            selectionCheckmark.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -4),
            selectionCheckmark.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -4),
            selectionCheckmark.widthAnchor.constraint(equalToConstant: 24),
            selectionCheckmark.heightAnchor.constraint(equalToConstant: 24),

            playIcon.centerXAnchor.constraint(equalTo: thumbnailView.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: thumbnailView.centerYAnchor)
        ])

        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
    }

    func configure(with swing: SavedSwing, isEditMode: Bool, isSelected: Bool = false) {
        thumbnailView.image = SwingStorage.shared.getThumbnail(for: swing)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        dateLabel.text = formatter.string(from: swing.date)

        deleteButton.isHidden = true  // Individual delete hidden in favor of bulk selection
        playIcon.isHidden = isEditMode
        selectionCheckmark.isHidden = !isEditMode || !isSelected

        // Visual feedback for selection
        thumbnailView.layer.borderWidth = isSelected ? 3 : 0
        thumbnailView.layer.borderColor = isSelected ? UIColor.systemBlue.cgColor : nil
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}

// MARK: - DualVideoPlayerViewController

final class DualVideoPlayerViewController: UIViewController {

    private let remoteURL: URL
    private let frontURL: URL
    private let remoteLine: LineData?
    private let frontLine: LineData?

    private var remotePlayer: AVPlayer?
    private var frontPlayer: AVPlayer?

    private let remotePlayerView = PlayerView()
    private let frontPlayerView = PlayerView()

    private let remoteDrawingLayer = CAShapeLayer()
    private let frontDrawingLayer = CAShapeLayer()

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

    private let speedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: ["0.15x", "0.25x", "0.5x", "1x"])
        control.selectedSegmentIndex = 1  // Default 0.25x
        control.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        control.selectedSegmentTintColor = UIColor.systemBlue.withAlphaComponent(0.8)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private var currentSpeed: Float = 0.25

    init(remoteURL: URL, frontURL: URL, remoteLine: LineData? = nil, frontLine: LineData? = nil) {
        self.remoteURL = remoteURL
        self.frontURL = frontURL
        self.remoteLine = remoteLine
        self.frontLine = frontLine
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
        setupDrawingLayers()
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
        view.addSubview(speedControl)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 50),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            playPauseButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            playPauseButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            speedControl.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            speedControl.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 20),
            speedControl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        speedControl.addTarget(self, action: #selector(speedChanged), for: .valueChanged)
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
            remote.rate = currentSpeed
            front.rate = currentSpeed
            let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
            playPauseButton.setImage(UIImage(systemName: "pause.circle.fill", withConfiguration: config), for: .normal)
        } else {
            remote.pause()
            front.pause()
            let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
            playPauseButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: config), for: .normal)
        }
    }

    @objc private func speedChanged() {
        switch speedControl.selectedSegmentIndex {
        case 0: currentSpeed = 0.15
        case 1: currentSpeed = 0.25
        case 2: currentSpeed = 0.5
        default: currentSpeed = 1.0
        }

        // Apply immediately if playing
        if remotePlayer?.rate != 0 {
            remotePlayer?.rate = currentSpeed
            frontPlayer?.rate = currentSpeed
        }
    }

    @objc private func playerDidFinish() {
        remotePlayer?.seek(to: .zero)
        frontPlayer?.seek(to: .zero)
        remotePlayer?.rate = currentSpeed
        frontPlayer?.rate = currentSpeed
    }

    private func setupDrawingLayers() {
        // Setup remote line
        remoteDrawingLayer.strokeColor = UIColor.systemYellow.cgColor
        remoteDrawingLayer.lineWidth = 3.0
        remoteDrawingLayer.lineCap = .round
        remoteDrawingLayer.fillColor = nil
        remotePlayerView.layer.addSublayer(remoteDrawingLayer)

        // Setup front line
        frontDrawingLayer.strokeColor = UIColor.systemYellow.cgColor
        frontDrawingLayer.lineWidth = 3.0
        frontDrawingLayer.lineCap = .round
        frontDrawingLayer.fillColor = nil
        frontPlayerView.layer.addSublayer(frontDrawingLayer)

        // Draw lines after layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.drawSavedLines()
        }
    }

    private func drawSavedLines() {
        // Draw remote line if exists - scale from normalized to view size
        if let line = remoteLine {
            let viewSize = remotePlayerView.bounds.size
            let path = UIBezierPath()
            path.move(to: line.start(in: viewSize))
            path.addLine(to: line.end(in: viewSize))
            remoteDrawingLayer.path = path.cgPath
            remoteDrawingLayer.frame = remotePlayerView.bounds
        }

        // Draw front line if exists - scale from normalized to view size
        if let line = frontLine {
            let viewSize = frontPlayerView.bounds.size
            let path = UIBezierPath()
            path.move(to: line.start(in: viewSize))
            path.addLine(to: line.end(in: viewSize))
            frontDrawingLayer.path = path.cgPath
            frontDrawingLayer.frame = frontPlayerView.bounds
        }
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
