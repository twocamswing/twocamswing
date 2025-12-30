import UIKit
import AVKit
import Photos

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

    private let exportSelectedButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Export", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.accessibilityIdentifier = "exportSelectedButton"
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
        toolbarView.addSubview(exportSelectedButton)
        toolbarView.addSubview(deleteSelectedButton)

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 50),

            selectAllButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 16),
            selectAllButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            exportSelectedButton.trailingAnchor.constraint(equalTo: deleteSelectedButton.leadingAnchor, constant: -16),
            exportSelectedButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            deleteSelectedButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -16),
            deleteSelectedButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor)
        ])

        selectAllButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)
        exportSelectedButton.addTarget(self, action: #selector(exportSelectedTapped), for: .touchUpInside)
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
        exportSelectedButton.isHidden = !isEditMode
        deleteSelectedButton.isHidden = !isEditMode

        // Clear selection when exiting edit mode
        if !isEditMode {
            selectedIndices.removeAll()
        }

        updateButtonStates()
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
        updateButtonStates()
        collectionView.reloadData()
    }

    @objc private func exportSelectedTapped() {
        guard !selectedIndices.isEmpty else { return }

        let count = selectedIndices.count
        let alert = UIAlertController(
            title: "Export \(count) Video\(count > 1 ? "s" : "")?",
            message: "Save to your photo library.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Export", style: .default) { [weak self] _ in
            self?.performExport()
        })
        present(alert, animated: true)
    }

    private func performExport() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    self?.exportVideosToPhotoLibrary()
                case .denied, .restricted:
                    self?.showPhotoLibraryDeniedAlert()
                case .notDetermined:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func exportVideosToPhotoLibrary() {
        let selectedSwings = selectedIndices.sorted().compactMap { index -> SavedSwing? in
            guard index < swings.count else { return nil }
            return swings[index]
        }

        var exportedCount = 0
        var errorCount = 0
        let group = DispatchGroup()

        for swing in selectedSwings {
            guard let remoteURL = SwingStorage.shared.getVideoURL(for: swing, front: false) else {
                errorCount += 1
                continue
            }

            let frontURL = SwingStorage.shared.getVideoURL(for: swing, front: true)

            if let frontURL = frontURL {
                // Merge both videos side-by-side
                group.enter()
                mergeSideBySide(remoteURL: remoteURL, frontURL: frontURL) { [weak self] mergedURL in
                    guard let mergedURL = mergedURL else {
                        errorCount += 1
                        group.leave()
                        return
                    }

                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: mergedURL)
                    }) { success, _ in
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: mergedURL)
                        if success {
                            exportedCount += 1
                        } else {
                            errorCount += 1
                        }
                        group.leave()
                    }
                }
            } else {
                // Single video only - export as-is
                group.enter()
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: remoteURL)
                }) { success, _ in
                    if success {
                        exportedCount += 1
                    } else {
                        errorCount += 1
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.showExportResultAlert(exported: exportedCount, errors: errorCount)
        }
    }

    private func mergeSideBySide(remoteURL: URL, frontURL: URL, completion: @escaping (URL?) -> Void) {
        let remoteAsset = AVAsset(url: remoteURL)
        let frontAsset = AVAsset(url: frontURL)

        // Create composition
        let composition = AVMutableComposition()

        guard let remoteTrack = remoteAsset.tracks(withMediaType: .video).first,
              let frontTrack = frontAsset.tracks(withMediaType: .video).first else {
            completion(nil)
            return
        }

        let duration = min(remoteAsset.duration, frontAsset.duration)

        // Add video tracks to composition
        guard let compositionRemoteTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionFrontTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(nil)
            return
        }

        do {
            try compositionRemoteTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: remoteTrack, at: .zero)
            try compositionFrontTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: frontTrack, at: .zero)
        } catch {
            completion(nil)
            return
        }

        // Get video sizes
        let remoteSize = remoteTrack.naturalSize.applying(remoteTrack.preferredTransform)
        let frontSize = frontTrack.naturalSize.applying(frontTrack.preferredTransform)

        let remoteWidth = abs(remoteSize.width)
        let remoteHeight = abs(remoteSize.height)
        let frontWidth = abs(frontSize.width)
        let frontHeight = abs(frontSize.height)

        // Output size: side by side, scaled to same height
        let outputHeight: CGFloat = max(remoteHeight, frontHeight)
        let remoteScaledWidth = remoteWidth * (outputHeight / remoteHeight)
        let frontScaledWidth = frontWidth * (outputHeight / frontHeight)
        let outputWidth = remoteScaledWidth + frontScaledWidth
        let outputSize = CGSize(width: outputWidth, height: outputHeight)

        // Create video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = outputSize

        // Layer instruction for front video (left side)
        let frontInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionFrontTrack)
        let frontScale = outputHeight / frontHeight
        var frontTransform = CGAffineTransform(scaleX: frontScale, y: frontScale)
        if frontSize.width < 0 || frontSize.height < 0 {
            frontTransform = frontTrack.preferredTransform.concatenating(CGAffineTransform(translationX: frontSize.width < 0 ? frontScaledWidth : 0, y: frontSize.height < 0 ? outputHeight : 0))
            frontTransform = frontTransform.scaledBy(x: frontScale, y: frontScale)
        }
        frontInstruction.setTransform(frontTransform, at: .zero)

        // Layer instruction for remote video (right side)
        let remoteInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionRemoteTrack)
        let remoteScale = outputHeight / remoteHeight
        var remoteTransform = CGAffineTransform(translationX: frontScaledWidth, y: 0)
        remoteTransform = remoteTransform.scaledBy(x: remoteScale, y: remoteScale)
        if remoteSize.width < 0 || remoteSize.height < 0 {
            remoteTransform = remoteTrack.preferredTransform.concatenating(CGAffineTransform(translationX: frontScaledWidth + (remoteSize.width < 0 ? remoteScaledWidth : 0), y: remoteSize.height < 0 ? outputHeight : 0))
        }
        remoteInstruction.setTransform(remoteTransform, at: .zero)

        // Main instruction
        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        mainInstruction.layerInstructions = [frontInstruction, remoteInstruction]

        videoComposition.instructions = [mainInstruction]

        // Create watermark overlay
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: outputSize)

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)

        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: outputSize)

        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)

        // Add watermark to left pane (front camera)
        addWatermark(to: overlayLayer, paneRect: CGRect(x: 0, y: 0, width: frontScaledWidth, height: outputHeight))

        // Add watermark to right pane (remote camera)
        addWatermark(to: overlayLayer, paneRect: CGRect(x: frontScaledWidth, y: 0, width: remoteScaledWidth, height: outputHeight))

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        // Export
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("merged_\(UUID().uuidString).mp4")

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil)
            return
        }

        exporter.outputURL = tempURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed {
                    completion(tempURL)
                } else {
                    print("Export failed: \(exporter.error?.localizedDescription ?? "unknown")")
                    completion(nil)
                }
            }
        }
    }

    private func addWatermark(to layer: CALayer, paneRect: CGRect) {
        let margin: CGFloat = 40
        let iconSize: CGFloat = 96
        let fontSize: CGFloat = 56

        // Container for icon + text
        let watermarkLayer = CALayer()

        // Load app icon
        if let iconImage = UIImage(named: "icon") ?? UIImage(named: "AppIcon") {
            let iconLayer = CALayer()
            iconLayer.contents = iconImage.cgImage
            iconLayer.frame = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
            iconLayer.contentsGravity = .resizeAspect
            watermarkLayer.addSublayer(iconLayer)
        }

        // Text layer
        let textLayer = CATextLayer()
        textLayer.string = "twocamswing.com"
        textLayer.font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.shadowColor = UIColor.black.cgColor
        textLayer.shadowOffset = CGSize(width: 2, height: 2)
        textLayer.shadowOpacity = 0.8
        textLayer.shadowRadius = 4
        textLayer.alignmentMode = .left
        textLayer.contentsScale = UIScreen.main.scale

        // Size text layer
        let textWidth: CGFloat = 480
        textLayer.frame = CGRect(x: iconSize + 16, y: 16, width: textWidth, height: fontSize + 16)

        watermarkLayer.addSublayer(textLayer)

        // Position watermark at bottom-right of pane
        let watermarkWidth = iconSize + 16 + textWidth
        let watermarkHeight = iconSize
        watermarkLayer.frame = CGRect(
            x: paneRect.maxX - watermarkWidth - margin,
            y: margin,  // Bottom in CALayer coordinates (y=0 is bottom)
            width: watermarkWidth,
            height: watermarkHeight
        )
        watermarkLayer.opacity = 0.7

        layer.addSublayer(watermarkLayer)
    }

    private func showExportResultAlert(exported: Int, errors: Int) {
        let title: String
        let message: String

        if errors == 0 {
            title = "Export Complete"
            message = "\(exported) video\(exported > 1 ? "s" : "") saved to Photos."
        } else if exported > 0 {
            title = "Partial Export"
            message = "\(exported) video\(exported > 1 ? "s" : "") saved. \(errors) failed."
        } else {
            title = "Export Failed"
            message = "Could not save videos to Photos."
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showPhotoLibraryDeniedAlert() {
        let alert = UIAlertController(
            title: "Photo Library Access Denied",
            message: "Please enable photo library access in Settings to export videos.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        present(alert, animated: true)
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
        updateButtonStates()
    }

    private func updateButtonStates() {
        let count = selectedIndices.count
        if count > 0 {
            exportSelectedButton.setTitle("Export (\(count))", for: .normal)
            exportSelectedButton.isEnabled = true
            deleteSelectedButton.setTitle("Delete (\(count))", for: .normal)
            deleteSelectedButton.isEnabled = true
        } else {
            exportSelectedButton.setTitle("Export", for: .normal)
            exportSelectedButton.isEnabled = false
            deleteSelectedButton.setTitle("Delete", for: .normal)
            deleteSelectedButton.isEnabled = false
        }
    }

    private func toggleSelection(at index: Int) {
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
        updateButtonStates()

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
