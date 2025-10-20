import UIKit
import WebRTC
import MultipeerConnectivity
import Foundation
import AVFoundation
import CoreImage

private final class ReplayCaptureRenderer: NSObject, RTCVideoRenderer {
    var onFrame: ((RTCVideoFrame) -> Void)?

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        onFrame?(frame)
    }
}

private struct ReplaySequence {
    struct Frame {
        let image: UIImage
        let displayTime: TimeInterval
    }

    var frames: [Frame] = []
    var currentIndex: Int = 0

    mutating func reset() {
        frames = []
        currentIndex = 0
    }
}

private final class ReplayBuffer {
    struct Entry {
        let image: UIImage
        let timestamp: TimeInterval
    }

    private let maxDuration: TimeInterval
    private var entries: [Entry] = []
    private let queue = DispatchQueue(label: "com.golfswingrtc.replaybuffer", qos: .userInteractive)

    init(maxDuration: TimeInterval = 3.0) {
        self.maxDuration = maxDuration
    }

    func append(image: UIImage, timestamp: TimeInterval) {
        queue.async {
            self.entries.append(Entry(image: image, timestamp: timestamp))
            self.trimIfNeeded(cutoff: timestamp - self.maxDuration)
        }
    }

    func recentEntries(duration: TimeInterval) -> [Entry] {
        let cutoff = CACurrentMediaTime() - duration
        return queue.sync {
            guard !entries.isEmpty else { return [] }
            var index = entries.startIndex
            while index < entries.endIndex && entries[index].timestamp < cutoff {
                index = entries.index(after: index)
            }
            return Array(entries[index..<entries.endIndex])
        }
    }

    private func trimIfNeeded(cutoff: TimeInterval) {
        guard !entries.isEmpty else { return }
        while entries.count > 1, let first = entries.first, first.timestamp < cutoff {
            entries.removeFirst()
        }
    }

    func clear() {
        queue.async {
            self.entries.removeAll()
        }
    }
}

private final class FrameImageConverter {
    static let shared = FrameImageConverter()

    private let ciContext = CIContext()

    private init() {}

    enum ResizeMode { case aspectFit, aspectFill }

    func makeImage(from pixelBuffer: CVPixelBuffer,
                   orientation: CGImagePropertyOrientation,
                   targetSize: CGSize?,
                   resizeMode: ResizeMode,
                   mirrorHorizontally: Bool = false) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = ciImage.oriented(forExifOrientation: Int32(orientation.rawValue))
        guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else { return nil }

        let baseImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)

        guard let targetSize, targetSize.width > 0, targetSize.height > 0 else {
            return baseImage
        }

        let inputWidth = CGFloat(oriented.extent.width)
        let inputHeight = CGFloat(oriented.extent.height)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: targetSize))

            let scale: CGFloat
            switch resizeMode {
            case .aspectFit:
                scale = min(targetSize.width / inputWidth, targetSize.height / inputHeight)
            case .aspectFill:
                scale = max(targetSize.width / inputWidth, targetSize.height / inputHeight)
            }

            let scaledWidth = inputWidth * scale
            let scaledHeight = inputHeight * scale
            let drawRect = CGRect(x: (targetSize.width - scaledWidth) / 2,
                                  y: (targetSize.height - scaledHeight) / 2,
                                  width: scaledWidth,
                                  height: scaledHeight)

            if mirrorHorizontally {
                ctx.cgContext.translateBy(x: drawRect.midX, y: drawRect.midY)
                ctx.cgContext.scaleBy(x: -1, y: 1)
                ctx.cgContext.translateBy(x: -drawRect.midX, y: -drawRect.midY)
            }

            baseImage.draw(in: drawRect)
        }
    }
}

class DebugVideoRenderer: NSObject, RTCVideoRenderer {
    private var frameCount = 0
    var lastFrameTime = Date()  // Made accessible for freeze detection
    private var lastLogTime = Date()
    private var lastFpsCalcTime = Date()  // Separate variable for FPS calculation

    func setSize(_ size: CGSize) {
        debugVideo("DebugRenderer setSize: \(size)")
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        frameCount += 1
        let now = Date()
        lastFrameTime = now  // Always update the actual last frame time

        // Log every 30 frames to avoid spam
        if frameCount % 30 == 0 || now.timeIntervalSince(lastLogTime) > 2.0 {
            let fps = 30.0 / now.timeIntervalSince(lastFpsCalcTime)
            debugFrame("DebugRenderer frame #\(frameCount): \(frame?.width ?? 0)x\(frame?.height ?? 0) @ \(String(format: "%.1f", fps))fps")
            lastFpsCalcTime = now
            lastLogTime = now
        }

        // Critical: Check for frame freeze - this check is now performed elsewhere in the monitoring timer
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("CameraPreviewView layer is not AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}

final class ReceiverViewController: UIViewController, RTCPeerConnectionDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var remoteVideoView: RTCMTLVideoView!
    private var remoteVideoContainer: UIView?
    private var peerConnection: RTCPeerConnection!
    private let factory: RTCPeerConnectionFactory = {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        if let h264 = encoderFactory.supportedCodecs().first(where: { $0.name == kRTCVideoCodecH264Name }) {
            encoderFactory.preferredCodec = h264
        }

        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()
    private let signaler = MPCSignaler(role: .browser)   // use .browser role
    private let debugRenderer = DebugVideoRenderer()
    private var splitContainer: UIStackView?
    private var frontPreviewContainer: UIView?
    private let frontPreviewView = CameraPreviewView()
    private var frontCameraSession: AVCaptureSession?
    private var frontCameraOutput: AVCaptureVideoDataOutput?
    private let frontCameraQueue = DispatchQueue(label: "com.golfswingrtc.receiver.frontcamera")
    private let frontCaptureOutputQueue = DispatchQueue(label: "com.golfswingrtc.receiver.frontcamera.output", qos: .userInteractive)
    private var currentPreviewOrientation: AVCaptureVideoOrientation = .portrait

    // Statistics tracking
    private var statsTimer: Timer?
    private var lastStatsTime = Date()
    private var bytesReceivedLastCheck: UInt64 = 0
    private var packetsReceivedLastCheck: UInt32 = 0

    // Replay infrastructure
    private let remoteReplayBuffer = ReplayBuffer()
    private let frontReplayBuffer = ReplayBuffer()
    private lazy var remoteReplayRenderer: ReplayCaptureRenderer = {
        let renderer = ReplayCaptureRenderer()
        renderer.onFrame = { [weak self] frame in
            self?.captureRemoteFrame(frame)
        }
        return renderer
    }()
    private let remoteReplayImageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()
    private let remoteFlipButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Remote Flip", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let frontReplayImageView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()
    private let replayButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Slow Replay", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let localFlipButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Local Flip", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private var isReplaying = false
    private var replayDisplayLink: CADisplayLink?
    private var replayStartTimestamp: CFTimeInterval?
    private var remoteReplaySequence = ReplaySequence()
    private var frontReplaySequence = ReplaySequence()
    private let replayWindow: TimeInterval = 3.0
    private let slowMotionFactor: Double = 2.0
    private var isRemoteMirrored = false
    private let remoteMirrorKey = "receiver.remoteMirror"
    private var remoteMirrorApplied = false
    private var isLocalMirrored = true
    private let localMirrorKey = "receiver.localMirror"
    private var remoteReplayTargetSize: CGSize = CGSize(width: 320, height: 320)
    private var frontReplayTargetSize: CGSize = CGSize(width: 320, height: 320)
    private var remoteResizeMode: FrameImageConverter.ResizeMode = .aspectFill

    deinit {
        stopReplay()
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        setupLayout()
        setupVideoView()
        setupFrontCameraPreview()
        setupPeerConnection()
        setupSignaler()
        startStatsMonitoring()
        replayButton.addTarget(self, action: #selector(handleReplayButtonTapped), for: .touchUpInside)
        remoteFlipButton.addTarget(self, action: #selector(handleRemoteFlipTapped), for: .touchUpInside)
        localFlipButton.addTarget(self, action: #selector(handleLocalFlipTapped), for: .touchUpInside)
        isRemoteMirrored = UserDefaults.standard.bool(forKey: remoteMirrorKey)
        remoteMirrorApplied = false
        syncRemoteMirrorUI(persist: false)
        if UserDefaults.standard.object(forKey: localMirrorKey) != nil {
            isLocalMirrored = UserDefaults.standard.bool(forKey: localMirrorKey)
        }
        syncLocalMirrorUI(persist: false)
        applyLocalMirrorTransform()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        updateFrontPreviewOrientation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startFrontCameraSessionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        stopFrontCameraSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        frontPreviewView.previewLayer.frame = frontPreviewView.bounds
        updateFrontPreviewOrientation()
        updateReplayTargetSizes()
    }

    private func setupLayout() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let frontContainer = UIView()
        frontContainer.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        frontContainer.layer.cornerRadius = 12
        frontContainer.layer.masksToBounds = true

        frontPreviewView.translatesAutoresizingMaskIntoConstraints = false
        frontPreviewView.isHidden = true
        frontContainer.addSubview(frontPreviewView)
        NSLayoutConstraint.activate([
            frontPreviewView.leadingAnchor.constraint(equalTo: frontContainer.leadingAnchor),
            frontPreviewView.trailingAnchor.constraint(equalTo: frontContainer.trailingAnchor),
            frontPreviewView.topAnchor.constraint(equalTo: frontContainer.topAnchor),
            frontPreviewView.bottomAnchor.constraint(equalTo: frontContainer.bottomAnchor)
        ])

        frontContainer.addSubview(frontReplayImageView)
        NSLayoutConstraint.activate([
            frontReplayImageView.leadingAnchor.constraint(equalTo: frontContainer.leadingAnchor),
            frontReplayImageView.trailingAnchor.constraint(equalTo: frontContainer.trailingAnchor),
            frontReplayImageView.topAnchor.constraint(equalTo: frontContainer.topAnchor),
            frontReplayImageView.bottomAnchor.constraint(equalTo: frontContainer.bottomAnchor)
        ])

        let frontLabel = UILabel()
        frontLabel.text = "Front Camera"
        frontLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        frontLabel.textColor = .white
        frontLabel.translatesAutoresizingMaskIntoConstraints = false
        frontContainer.addSubview(frontLabel)
        NSLayoutConstraint.activate([
            frontLabel.topAnchor.constraint(equalTo: frontContainer.topAnchor, constant: 12),
            frontLabel.leadingAnchor.constraint(equalTo: frontContainer.leadingAnchor, constant: 12)
        ])

        frontContainer.addSubview(replayButton)
        NSLayoutConstraint.activate([
            replayButton.leadingAnchor.constraint(equalTo: frontContainer.leadingAnchor, constant: 12),
            replayButton.bottomAnchor.constraint(equalTo: frontContainer.bottomAnchor, constant: -12)
        ])

        frontContainer.addSubview(localFlipButton)
        NSLayoutConstraint.activate([
            localFlipButton.trailingAnchor.constraint(equalTo: frontContainer.trailingAnchor, constant: -12),
            localFlipButton.topAnchor.constraint(equalTo: frontContainer.topAnchor, constant: 12)
        ])

        let remoteContainer = UIView()
        remoteContainer.backgroundColor = .black

        stack.addArrangedSubview(frontContainer)
        stack.addArrangedSubview(remoteContainer)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])

        splitContainer = stack
        frontPreviewContainer = frontContainer
        remoteVideoContainer = remoteContainer
    }

    private func setupVideoView() {
        guard let remoteContainer = remoteVideoContainer else { return }
        let remoteView = RTCMTLVideoView(frame: .zero)
        remoteView.translatesAutoresizingMaskIntoConstraints = false
        remoteView.videoContentMode = UIDevice.current.userInterfaceIdiom == .pad ? .scaleAspectFit : .scaleAspectFill
        remoteView.backgroundColor = .black

        remoteContainer.addSubview(remoteView)
        NSLayoutConstraint.activate([
            remoteView.leadingAnchor.constraint(equalTo: remoteContainer.leadingAnchor),
            remoteView.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor),
            remoteView.topAnchor.constraint(equalTo: remoteContainer.topAnchor),
            remoteView.bottomAnchor.constraint(equalTo: remoteContainer.bottomAnchor)
        ])

        remoteVideoView = remoteView

        remoteContainer.addSubview(remoteReplayImageView)
        NSLayoutConstraint.activate([
            remoteReplayImageView.leadingAnchor.constraint(equalTo: remoteContainer.leadingAnchor),
            remoteReplayImageView.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor),
            remoteReplayImageView.topAnchor.constraint(equalTo: remoteContainer.topAnchor),
            remoteReplayImageView.bottomAnchor.constraint(equalTo: remoteContainer.bottomAnchor)
        ])

        remoteResizeMode = remoteView.videoContentMode == .scaleAspectFit ? .aspectFit : .aspectFill
        remoteReplayImageView.contentMode = remoteResizeMode == .aspectFit ? .scaleAspectFit : .scaleAspectFill

        remoteContainer.addSubview(remoteFlipButton)
        NSLayoutConstraint.activate([
            remoteFlipButton.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor, constant: -12),
            remoteFlipButton.topAnchor.constraint(equalTo: remoteContainer.topAnchor, constant: 12)
        ])

        syncRemoteMirrorUI(persist: false)
        applyRemoteMirrorTransformIfPossible()
        updateReplayTargetSizes()

        debugVideo("setupVideoView completed - container: \(String(describing: remoteVideoContainer?.frame))")
        debugVideo("Video view added to container: \(remoteVideoView.superview != nil)")
        debugVideo("Device screen bounds: \(UIScreen.main.bounds)")
        debugVideo("Device scale: \(UIScreen.main.scale)")

        setupVideoViewDiagnostics()
    }

    private func setupFrontCameraPreview() {
        guard let previewContainer = frontPreviewContainer else { return }
        previewContainer.isHidden = true

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureFrontCameraSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else {
                        debugVideo("Front camera preview denied by user")
                        self?.frontPreviewContainer?.isHidden = true
                        return
                    }
                    self?.configureFrontCameraSession()
                }
            }
        default:
            debugVideo("Front camera preview skipped due to authorization status \(status.rawValue)")
            previewContainer.isHidden = true
        }
    }

    private func configureFrontCameraSession() {
        guard frontCameraSession == nil else {
            frontPreviewContainer?.isHidden = false
            startFrontCameraSessionIfNeeded()
            return
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            debugVideo("Front camera device not available")
            frontPreviewContainer?.isHidden = true
            return
        }

        do {
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .medium

            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            let previewLayer = frontPreviewView.previewLayer
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = frontPreviewView.bounds
            previewLayer.needsDisplayOnBoundsChange = true

            // IMPORTANT: Avoid poking at broader AVCaptureConnection state; Orange iPad (iOS 18.6.2)
            // was crashing when we queried mirroring support. Orientation is handled separately via
            // updateFrontPreviewOrientation().
            if let label = frontPreviewContainer?.subviews.compactMap({ $0 as? UILabel }).first {
                frontPreviewContainer?.bringSubviewToFront(label)
            }
            frontPreviewContainer?.bringSubviewToFront(replayButton)

            frontPreviewView.isHidden = false
            frontPreviewContainer?.isHidden = false

            let dataOutput = AVCaptureVideoDataOutput()
            dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            dataOutput.alwaysDiscardsLateVideoFrames = true
            dataOutput.setSampleBufferDelegate(self, queue: frontCaptureOutputQueue)
            if session.canAddOutput(dataOutput) {
                session.addOutput(dataOutput)
            }
            frontCameraOutput = dataOutput

            session.commitConfiguration()

            frontCameraSession = session

            startFrontCameraSessionIfNeeded()
            updateFrontPreviewOrientation()
            applyLocalMirrorTransform()
            updateReplayTargetSizes()
        } catch {
            debugVideo("Failed to configure front camera preview: \(error.localizedDescription)")
            frontPreviewContainer?.isHidden = true
        }
    }

    private func startFrontCameraSessionIfNeeded() {
        guard let session = frontCameraSession, !session.isRunning else { return }
        frontCameraQueue.async { session.startRunning() }
    }

    private func stopFrontCameraSession() {
        guard let session = frontCameraSession, session.isRunning else { return }
        frontCameraQueue.async { session.stopRunning() }
    }

    @objc private func handleDeviceOrientationChange() {
        updateFrontPreviewOrientation()
    }

    private func updateFrontPreviewOrientation() {
        let orientation = resolvedVideoOrientation()
        currentPreviewOrientation = orientation
        if let connection = frontPreviewView.previewLayer.connection,
           connection.isVideoOrientationSupported,
           connection.videoOrientation != orientation {
            connection.videoOrientation = orientation
        }
        if let dataOutputConnection = frontCameraOutput?.connection(with: .video),
           dataOutputConnection.isVideoOrientationSupported,
           dataOutputConnection.videoOrientation != orientation {
            dataOutputConnection.videoOrientation = orientation
        }
    }

    private func resolvedVideoOrientation() -> AVCaptureVideoOrientation {
        if let interfaceOrientation = view.window?.windowScene?.interfaceOrientation {
            switch interfaceOrientation {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            case .unknown: break
            @unknown default: break
            }
        }

        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight  // device rotated left -> camera needs opposite
        case .landscapeRight: return .landscapeLeft
        default: return .portrait
        }
    }

    private func captureRemoteFrame(_ frame: RTCVideoFrame) {
        guard !isReplaying else { return }
        guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
        guard remoteReplayTargetSize.width > 0, remoteReplayTargetSize.height > 0 else { return }
        if !remoteMirrorApplied {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.remoteMirrorApplied {
                    self.remoteMirrorApplied = self.applyRemoteMirrorTransformIfPossible()
                }
            }
        }
        let orientation = CGImagePropertyOrientation.from(rotation: frame.rotation)
        guard let image = FrameImageConverter.shared.makeImage(from: buffer.pixelBuffer,
                                                               orientation: orientation,
                                                               targetSize: remoteReplayTargetSize,
                                                               resizeMode: remoteResizeMode) else { return }
        remoteReplayBuffer.append(image: image, timestamp: CACurrentMediaTime())
    }

    private func captureFrontFrame(pixelBuffer: CVPixelBuffer) {
        guard frontReplayTargetSize.width > 0, frontReplayTargetSize.height > 0 else { return }
        let orientation = CGImagePropertyOrientation.from(captureOrientation: currentPreviewOrientation)
        let connectionMirrored = frontCameraOutput?
            .connection(with: .video)?
            .isVideoMirrored ?? false
        let mirrorForReplay = isLocalMirrored && !connectionMirrored
        guard let image = FrameImageConverter.shared.makeImage(from: pixelBuffer,
                                                               orientation: orientation,
                                                               targetSize: frontReplayTargetSize,
                                                               resizeMode: .aspectFill,
                                                               mirrorHorizontally: mirrorForReplay) else { return }
        frontReplayBuffer.append(image: image, timestamp: CACurrentMediaTime())
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isReplaying,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        captureFrontFrame(pixelBuffer: pixelBuffer)
    }

    @objc private func handleReplayButtonTapped() {
        guard !isReplaying else { return }

        let remoteEntries = remoteReplayBuffer.recentEntries(duration: replayWindow)
        let frontEntries = frontReplayBuffer.recentEntries(duration: replayWindow)

        guard !remoteEntries.isEmpty || !frontEntries.isEmpty else {
            debugVideo("Replay requested but buffers are empty")
            return
        }

        remoteReplaySequence = makeReplaySequence(from: remoteEntries, slowFactor: slowMotionFactor)
        frontReplaySequence = makeReplaySequence(from: frontEntries, slowFactor: slowMotionFactor)

        guard !remoteReplaySequence.frames.isEmpty || !frontReplaySequence.frames.isEmpty else {
            debugVideo("Replay sequences could not be constructed")
            return
        }

        isReplaying = true
        replayButton.isEnabled = false

        let hasRemoteReplay = !remoteReplaySequence.frames.isEmpty
        let hasFrontReplay = !frontReplaySequence.frames.isEmpty

        remoteVideoView.isHidden = hasRemoteReplay
        remoteReplayImageView.isHidden = !hasRemoteReplay
        frontPreviewView.isHidden = hasFrontReplay
        frontReplayImageView.isHidden = !hasFrontReplay

        remoteReplayImageView.image = remoteReplaySequence.frames.first?.image
        frontReplayImageView.image = frontReplaySequence.frames.first?.image
        frontReplayImageView.transform = .identity

        replayStartTimestamp = CACurrentMediaTime()
        let displayLink = CADisplayLink(target: self, selector: #selector(handleReplayTick(_:)))
        displayLink.add(to: .main, forMode: .common)
        replayDisplayLink = displayLink
    }

    @objc private func handleReplayTick(_ displayLink: CADisplayLink) {
        guard let start = replayStartTimestamp else { return }
        let elapsed = CACurrentMediaTime() - start

        let remoteFinished = advance(sequence: &remoteReplaySequence, elapsed: elapsed, imageView: remoteReplayImageView)
        let frontFinished = advance(sequence: &frontReplaySequence, elapsed: elapsed, imageView: frontReplayImageView)

        if remoteFinished && frontFinished {
            stopReplay()
        }
    }

    private func advance(sequence: inout ReplaySequence, elapsed: TimeInterval, imageView: UIImageView) -> Bool {
        guard !sequence.frames.isEmpty else { return true }

        while sequence.currentIndex < sequence.frames.count,
              sequence.frames[sequence.currentIndex].displayTime <= elapsed {
            imageView.image = sequence.frames[sequence.currentIndex].image
            sequence.currentIndex += 1
        }

        return sequence.currentIndex >= sequence.frames.count
    }

    private func stopReplay() {
        replayDisplayLink?.invalidate()
        replayDisplayLink = nil
        replayStartTimestamp = nil
        remoteReplayImageView.isHidden = true
        frontReplayImageView.isHidden = true
        remoteVideoView.isHidden = false
        frontPreviewView.isHidden = false
        isReplaying = false
        replayButton.isEnabled = true
        remoteReplaySequence.reset()
        frontReplaySequence.reset()
    }

    @objc private func handleRemoteFlipTapped() {
        isRemoteMirrored.toggle()
        syncRemoteMirrorUI(persist: true)
        remoteMirrorApplied = applyRemoteMirrorTransformIfPossible()
    }

    private func syncRemoteMirrorUI(persist: Bool) {
        let scaleX: CGFloat = isRemoteMirrored ? -1 : 1
        let transform = CGAffineTransform(scaleX: scaleX, y: 1)
        remoteReplayImageView.transform = transform
        let title = isRemoteMirrored ? "Remote Unflip" : "Remote Flip"
        remoteFlipButton.setTitle(title, for: .normal)
        if persist {
            UserDefaults.standard.set(isRemoteMirrored, forKey: remoteMirrorKey)
        }
    }

    @discardableResult
    private func applyRemoteMirrorTransformIfPossible() -> Bool {
        guard let remoteView = remoteVideoView else { return false }
        let scaleX: CGFloat = isRemoteMirrored ? -1 : 1
        remoteView.transform = CGAffineTransform(scaleX: scaleX, y: 1)
        remoteMirrorApplied = true
        return true
    }

    @objc private func handleLocalFlipTapped() {
        isLocalMirrored.toggle()
        syncLocalMirrorUI(persist: true)
        applyLocalMirrorTransform()
        frontReplayBuffer.clear()
    }

    private func syncLocalMirrorUI(persist: Bool) {
        let title = isLocalMirrored ? "Local Unflip" : "Local Flip"
        localFlipButton.setTitle(title, for: .normal)
        if persist {
            UserDefaults.standard.set(isLocalMirrored, forKey: localMirrorKey)
        }
    }

    private func applyLocalMirrorTransform() {
        if let connection = frontPreviewView.previewLayer.connection,
           connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }
            connection.isVideoMirrored = isLocalMirrored
        }

        if let dataOutputConnection = frontCameraOutput?.connection(with: .video),
           dataOutputConnection.isVideoMirroringSupported {
            if dataOutputConnection.automaticallyAdjustsVideoMirroring {
                dataOutputConnection.automaticallyAdjustsVideoMirroring = false
            }
            dataOutputConnection.isVideoMirrored = isLocalMirrored
        }
    }

    private func updateReplayTargetSizes() {
        if let remoteView = remoteVideoView {
            remoteReplayTargetSize = computeTargetSize(for: remoteView.bounds.size)
        }
        frontReplayTargetSize = computeTargetSize(for: frontPreviewView.bounds.size)
    }

    private func computeTargetSize(for bounds: CGSize) -> CGSize {
        let maxDimension: CGFloat = 720
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let maxSide = max(width, height)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        return CGSize(width: width * scale, height: height * scale)
    }

    private func makeReplaySequence(from entries: [ReplayBuffer.Entry], slowFactor: Double) -> ReplaySequence {
        guard !entries.isEmpty else { return ReplaySequence() }
        guard let first = entries.first, let last = entries.last else { return ReplaySequence() }

        let totalDuration = max(last.timestamp - first.timestamp, 1.0 / 30.0)
        let playbackDuration = totalDuration * slowFactor
        let count = entries.count

        if count == 1 {
            return ReplaySequence(frames: [ReplaySequence.Frame(image: first.image, displayTime: 0)], currentIndex: 0)
        }

        let step = playbackDuration / Double(count - 1)
        var frames: [ReplaySequence.Frame] = []
        frames.reserveCapacity(count)
        for (index, entry) in entries.enumerated() {
            frames.append(ReplaySequence.Frame(image: entry.image, displayTime: step * Double(index)))
        }
        return ReplaySequence(frames: frames, currentIndex: 0)
    }

    private func setupVideoViewDiagnostics() {
        // Monitor video view rendering state periodically
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.logVideoViewState()
        }
    }
    private func logVideoViewState() {
        debugVideo("=== VIDEO VIEW STATE ===")
        debugVideo("Frame: \(remoteVideoView.frame)")
        debugVideo("Bounds: \(remoteVideoView.bounds)")
        debugVideo("Hidden: \(remoteVideoView.isHidden)")
        debugVideo("Alpha: \(remoteVideoView.alpha)")
        debugVideo("Transform: \(remoteVideoView.transform)")
        debugVideo("SuperView: \(remoteVideoView.superview != nil)")
        debugVideo("Background: \(remoteVideoView.backgroundColor?.description ?? "nil")")
        debugVideo("Content mode: \(remoteVideoView.videoContentMode.rawValue)")

        // Check view hierarchy
        if let superview = remoteVideoView.superview {
            debugVideo("In view hierarchy - superview bounds: \(superview.bounds)")
            debugVideo("Subview index: \(superview.subviews.firstIndex(of: remoteVideoView) ?? -1)")
            debugVideo("Total subviews: \(superview.subviews.count)")
        }

        // Force a layout update and check for changes
        let oldFrame = remoteVideoView.frame
        remoteVideoView.setNeedsLayout()
        remoteVideoView.layoutIfNeeded()
        if oldFrame != remoteVideoView.frame {
            debugVideo("Layout caused frame change: \(oldFrame) → \(remoteVideoView.frame)")
        }
    }

    private func setupPeerConnection() {
        let config = RTCConfiguration()
        // Use multiple STUN servers for better connectivity
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun2.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan
        config.iceTransportPolicy = .all
        config.bundlePolicy = .balanced
        config.rtcpMuxPolicy = .require
        config.iceCandidatePoolSize = 2
        config.continualGatheringPolicy = .gatherContinually
        config.disableLinkLocalNetworks = false

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    private func setupSignaler() {
        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }
            switch msg {
            case .offer(let sdpText):
                print("Receiver: Received offer SDP contains video: \(sdpText.contains("m=video"))")
                print("Receiver: Received offer SDP video lines: \(sdpText.components(separatedBy: "\n").filter { $0.contains("video") }.count)")

                // Only handle offers that contain video - ignore initial empty offers
                if !sdpText.contains("m=video") {
                    print("Receiver: Ignoring offer without video track - waiting for renegotiation with video")
                    return
                }

                print("Receiver: Processing offer with video track")
                let offer = RTCSessionDescription(type: .offer, sdp: sdpText)
                self.peerConnection.setRemoteDescription(offer) { error in
                    if let error = error {
                        print("Receiver: failed to set offer: \(error)")
                        return
                    }

                    let constraints = RTCMediaConstraints(
                        mandatoryConstraints: ["OfferToReceiveVideo": "true"],
                        optionalConstraints: nil
                    )
                    self.peerConnection.answer(for: constraints) { sdp, err in
                        guard let sdp = sdp, err == nil else {
                            print("Receiver: answer error \(String(describing: err))")
                            return
                        }
                        self.peerConnection.setLocalDescription(sdp) { err in
                            print("Receiver: setLocalDescription(answer) \(err?.localizedDescription ?? "ok")")
                        }
                        print("Receiver: Answer SDP contains video: \(sdp.sdp.contains("m=video"))")
                        print("Receiver: Answer SDP video lines: \(sdp.sdp.components(separatedBy: "\n").filter { $0.contains("video") }.count)")
                        print("Receiver: sending answer")
                        self.signaler.send(SignalMessage.answer(sdp))
                    }
                }

            case .candidate(let candidateSdp, let sdpMid, let sdpMLineIndex):
                let candidate = RTCIceCandidate(
                    sdp: candidateSdp,
                    sdpMLineIndex: sdpMLineIndex,
                    sdpMid: sdpMid
                )
                self.peerConnection.add(candidate) { error in
                    if let error = error {
                        print("Receiver: failed to add candidate: \(error)")
                    } else {
                        print("Receiver: added candidate successfully")
                    }
                }

            case .answer:
                // receiver never expects an answer
                break
            }
        }
    }

    // MARK: - RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Receiver: signaling → \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Receiver: didAdd stream with \(stream.videoTracks.count) video tracks")
        print("Receiver: Stream ID: \(stream.streamId)")
        for (index, track) in stream.videoTracks.enumerated() {
            print("Receiver: Video track \(index): ID=\(track.trackId) enabled=\(track.isEnabled) state=\(track.readyState.rawValue)")
        }
        // Note: Using rtpReceiver method instead for modern WebRTC
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("Receiver: didRemove stream")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("Receiver: should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let stateName: String
        switch newState {
        case .new: stateName = "new"
        case .checking: stateName = "checking"
        case .connected: stateName = "connected"
        case .completed: stateName = "completed"
        case .failed: stateName = "failed"
        case .disconnected: stateName = "disconnected"
        case .closed: stateName = "closed"
        case .count: stateName = "count"
        @unknown default: stateName = "unknown(\(newState.rawValue))"
        }
        print("Receiver: ICE state → \(stateName) (\(newState.rawValue))")

        if newState == .failed {
            print("Receiver: ICE CONNECTION FAILED")
        } else if newState == .disconnected {
            print("Receiver: ICE DISCONNECTED - connection may be unstable")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Receiver: ICE gathering → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let candidateString = candidate.sdp
        print("Receiver: generated candidate: \(candidateString.prefix(60))...")
        signaler.send(SignalMessage.candidate(candidate))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("Receiver: removed candidates")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("Receiver: data channel opened")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        print("🔥 RECEIVER: didAdd rtpReceiver called! This is the key callback for modern WebRTC!")
        print("Receiver: didAdd rtpReceiver with \(streams.count) streams")
        print("Receiver: rtpReceiver.track type: \(type(of: rtpReceiver.track))")
        print("Receiver: rtpReceiver.track.kind: \(rtpReceiver.track?.kind ?? "nil")")
        print("Receiver: rtpReceiver.track enabled: \(rtpReceiver.track?.isEnabled ?? false)")
        print("Receiver: rtpReceiver parameters: \(rtpReceiver.parameters)")

        if let track = rtpReceiver.track as? RTCVideoTrack {
            debugVideo("Video track found, attaching to view...")
            DispatchQueue.main.async {
                debugVideo("On main queue, video view frame: \(self.remoteVideoView.frame)")
                debugVideo("Video view superview: \(self.remoteVideoView.superview != nil)")
                debugVideo("Track is enabled: \(track.isEnabled)")

                // CRITICAL: Ensure track is enabled BEFORE attaching
                if !track.isEnabled {
                    debugVideo("WARNING: Track was disabled, enabling it now")
                    track.isEnabled = true
                }

                // Track attachment with detailed logging
                debugVideo("Attaching track to RTCMTLVideoView...")
                track.add(self.remoteVideoView)
                debugVideo("RTCMTLVideoView attachment completed")

                debugVideo("Attaching track to debug renderer...")
                track.add(self.debugRenderer)
                debugVideo("Debug renderer attachment completed")

                track.add(self.remoteReplayRenderer)
                debugVideo("Replay renderer attached")

                // Don't apply rotation transforms - just use proper content mode
                self.handleVideoRotation(track: track)

                if !self.remoteMirrorApplied {
                    if !self.applyRemoteMirrorTransformIfPossible() {
                        self.remoteMirrorApplied = false
                    }
                }

                debugVideo("Video track state: enabled=\(track.isEnabled) readyState=\(track.readyState.rawValue)")

                // Monitor video track state changes
                self.startVideoTrackMonitoring(track: track)

                // Force video view to front and refresh
                if let container = self.remoteVideoContainer {
                    self.view.bringSubviewToFront(container)
                }
                if let preview = self.frontPreviewContainer {
                    self.view.bringSubviewToFront(preview)
                }
                self.remoteVideoView.setNeedsLayout()
                self.remoteVideoView.layoutIfNeeded()

                // Keep checking that track stays enabled
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                    if !track.isEnabled {
                        debugCritical("Track became disabled! Re-enabling...")
                        track.isEnabled = true
                    }
                    // Stop after 10 seconds
                    if timer.fireDate.timeIntervalSinceNow > 10 {
                        timer.invalidate()
                    }
                }
            }
        } else {
            debugCritical("No video track found in rtpReceiver!")
        }
    }

    private func handleVideoRotation(track: RTCVideoTrack) {
        // Don't rotate here - the rotation issue is likely in how WebRTC handles orientation
        // Instead, we should configure the video view properly
        debugVideo("handleVideoRotation called - resetting to defaults")

        // Reset any previous transforms
        remoteVideoView.transform = .identity
        remoteVideoView.setNeedsLayout()
        remoteVideoView.layoutIfNeeded()

        // The real fix: Set the video content mode to handle aspect ratio properly
        // For landscape iPads showing portrait video
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Use scaleAspectFit to show the entire video without distortion
            remoteVideoView.videoContentMode = .scaleAspectFit
            debugVideo("iPad detected - using scaleAspectFit for proper aspect ratio")
        } else {
            remoteVideoView.videoContentMode = .scaleAspectFill
            debugVideo("iPhone detected - using scaleAspectFill")
        }
    }

    private func startVideoTrackMonitoring(track: RTCVideoTrack) {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self, weak track] timer in
            guard let self = self, let track = track else {
                timer.invalidate()
                return
            }

            debugVideo("=== VIDEO TRACK STATE ===")
            debugVideo("Track enabled: \(track.isEnabled)")
            debugVideo("Track ready state: \(track.readyState.rawValue)")
            debugVideo("Track kind: \(track.kind)")
            debugVideo("Track ID: \(track.trackId)")

            // Check if track state changed unexpectedly
            if !track.isEnabled {
                debugCritical("Video track became DISABLED!")
            }
            if track.readyState.rawValue == 3 { // ended
                debugCritical("Video track ENDED!")
            }

            // Check for actual frame freeze using debug renderer's last frame time
            if let lastFrameTime = (self.debugRenderer as? DebugVideoRenderer)?.lastFrameTime {
                let timeSinceLastFrame = Date().timeIntervalSince(lastFrameTime)
                if timeSinceLastFrame > 3.0 {
                    debugCritical("Frame delivery STOPPED! \(String(format: "%.1f", timeSinceLastFrame))s since last frame")
                }
            }
        }
    }


    // MARK: - Statistics and Diagnostics

    private func startStatsMonitoring() {
        if DebugFlags.webrtcStats {
            statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                self.logWebRTCStats()
            }
        }
    }

    private func logWebRTCStats() {
        guard peerConnection != nil else { return }

        peerConnection.statistics { [weak self] stats in
            guard let self = self else { return }

            let currentTime = Date()
            let timeDiff = currentTime.timeIntervalSince(self.lastStatsTime)
            self.lastStatsTime = currentTime

            print("📊 RECEIVER WEBRTC STATS (Δ\(String(format: "%.1f", timeDiff))s):")

            var bytesReceived: UInt64 = 0
            var packetsReceived: UInt32 = 0
            var packetsLost: UInt32 = 0
            var framesPerSecond: Double = 0
            var frameWidth: UInt32 = 0
            var frameHeight: UInt32 = 0
            var decoderImplementation = "unknown"
            var framesDecoded: UInt64 = 0
            var framesDropped: UInt64 = 0
            var jitter: Double = 0
            var bitrateMbps: Double = 0

            for stat in stats.statistics.values {
                // Inbound RTP (what we're receiving)
                if stat.type == "inbound-rtp" && stat.values["mediaType"] as? String == "video" {
                    if let bytes = stat.values["bytesReceived"] as? UInt64 {
                        bytesReceived = bytes
                    }
                    if let packets = stat.values["packetsReceived"] as? UInt32 {
                        packetsReceived = packets
                    }
                    if let lost = stat.values["packetsLost"] as? UInt32 {
                        packetsLost = lost
                    }
                    if let fps = stat.values["framesPerSecond"] as? Double {
                        framesPerSecond = fps
                    }
                    if let width = stat.values["frameWidth"] as? UInt32 {
                        frameWidth = width
                    }
                    if let height = stat.values["frameHeight"] as? UInt32 {
                        frameHeight = height
                    }
                    if let impl = stat.values["decoderImplementation"] as? String {
                        decoderImplementation = impl
                    }
                    if let decoded = stat.values["framesDecoded"] as? UInt64 {
                        framesDecoded = decoded
                    }
                    if let dropped = stat.values["framesDropped"] as? UInt64 {
                        framesDropped = dropped
                    }
                    if let j = stat.values["jitter"] as? Double {
                        jitter = j
                    }
                }

                // Candidate pair (connection quality)
                if stat.type == "candidate-pair" && stat.values["state"] as? String == "succeeded" {
                    if let rtt = stat.values["currentRoundTripTime"] as? Double {
                        print("  📡 RTT: \(String(format: "%.0f", rtt * 1000))ms")
                    }
                    if let available = stat.values["availableIncomingBitrate"] as? Double {
                        print("  📈 Available incoming: \(String(format: "%.1f", available / 1000000))Mbps")
                    }
                }

                // Video track stats
                if stat.type == "track" && stat.values["kind"] as? String == "video" {
                    if let frozen = stat.values["freezeCount"] as? UInt32 {
                        print("  🧊 Freeze events: \(frozen)")
                    }
                    if let totalFreezeTime = stat.values["totalFreezesDuration"] as? Double {
                        print("  ⏸️ Total freeze time: \(String(format: "%.2f", totalFreezeTime))s")
                    }
                }
            }

            // Calculate bitrate
            let bytesDiff = bytesReceived - self.bytesReceivedLastCheck
            let packetsDiff = packetsReceived - self.packetsReceivedLastCheck
            bitrateMbps = (Double(bytesDiff) * 8.0) / (timeDiff * 1000000.0)

            print("  📥 Bytes received: \(bytesReceived) (Δ\(bytesDiff))")
            print("  📦 Packets received: \(packetsReceived) (Δ\(packetsDiff)), lost: \(packetsLost)")
            print("  🎬 Decoded: \(frameWidth)x\(frameHeight) @ \(String(format: "%.1f", framesPerSecond))fps")
            print("  🔧 Decoder: \(decoderImplementation)")
            print("  🎞️ Frames decoded: \(framesDecoded), dropped: \(framesDropped)")
            print("  📶 Jitter: \(String(format: "%.2f", jitter * 1000))ms")
            print("  🚀 Bitrate: \(String(format: "%.2f", bitrateMbps))Mbps")

            // Update for next calculation
            self.bytesReceivedLastCheck = bytesReceived
            self.packetsReceivedLastCheck = packetsReceived

            // Health checks
            if framesPerSecond < 5.0 && framesPerSecond > 0 {
                print("  ⚠️ WARNING: Low FPS (\(framesPerSecond)) - decoding issues?")
            }

            if bitrateMbps < 0.1 && bytesDiff == 0 && timeDiff > 3.0 {
                print("  🚨 CRITICAL: No bytes received in \(String(format: "%.1f", timeDiff))s - stream frozen!")
            }

            if packetsLost > 0 {
                print("  ⚠️ WARNING: \(packetsLost) packets lost - network issues?")
            }

            if framesDropped > 0 && timeDiff > 1.0 {
                print("  ⚠️ WARNING: \(framesDropped) frames dropped - performance issues?")
            }

            let packetLossRate = packetsReceived > 0 ? Double(packetsLost) / Double(packetsReceived) * 100 : 0
            if packetLossRate > 5.0 {
                print("  🚨 HIGH PACKET LOSS: \(String(format: "%.1f", packetLossRate))%")
            }
        }
    }
}

private extension CGImagePropertyOrientation {
    static func from(rotation: RTCVideoRotation) -> CGImagePropertyOrientation {
        switch rotation {
        case ._0: return .up
        case ._90: return .right
        case ._180: return .down
        case ._270: return .left
        @unknown default: return .up
        }
    }

    static func from(captureOrientation: AVCaptureVideoOrientation, mirrored: Bool = false) -> CGImagePropertyOrientation {
        switch captureOrientation {
        case .portrait: return mirrored ? .leftMirrored : .right
        case .portraitUpsideDown: return mirrored ? .rightMirrored : .left
        case .landscapeRight: return mirrored ? .upMirrored : .up
        case .landscapeLeft: return mirrored ? .downMirrored : .down
        @unknown default: return mirrored ? .upMirrored : .up
        }
    }
}
