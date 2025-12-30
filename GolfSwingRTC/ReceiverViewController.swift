import UIKit
import WebRTC
import MultipeerConnectivity
import Foundation
import AVFoundation
import CoreImage
import QuartzCore

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
    private var isConfiguringFrontCamera = false
    private let frontCaptureOutputQueue = DispatchQueue(label: "com.golfswingrtc.receiver.frontcamera.output", qos: .userInteractive)
    private var currentPreviewOrientation: AVCaptureVideoOrientation = .portrait

    // Statistics tracking
    private var statsTimer: Timer?
    private var lastStatsTime = Date()
    private var bytesReceivedLastCheck: UInt64 = 0
    private var packetsReceivedLastCheck: UInt32 = 0

    // MPC Video Fallback with H.264 decoding
    private var mpcVideoImageView: UIImageView?
    private var mpcFrameCount = 0
    private var usingMPCVideo = false
    private let h264Decoder = HardwareH264Decoder()
    private let mpcCIContext = CIContext()
    private var currentMPCRotation: Int = 0  // Store current rotation for decoded frames

    // Connection status UI
    private var connectionStatusLabel: UILabel?
    private var connectionStartTime: Date?
    private var connectionTimer: Timer?
    private var iceCheckingStarted = false

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
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        button.setImage(UIImage(systemName: "hand.tap.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        button.layer.cornerRadius = 28
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "replayButton"
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
    private var slowMotionFactor: Double = 2.0
    private var isRemoteMirrored = false
    private let remoteMirrorKey = "receiver.remoteMirror"
    private var remoteMirrorApplied = false
    private var isLocalMirrored = true
    private let localMirrorKey = "receiver.localMirror"

    // Sound-triggered replay
    private let audioDetector = AudioImpactDetector()
    private var triggerModeControl: UISegmentedControl?
    private var sensitivitySlider: UISlider?
    private var sensitivityLabel: UILabel?
    private var sensitivityContainer: UIStackView?
    private let triggerModeKey = "receiver.replayTriggerMode"  // 0 = manual, 1 = sound
    private let sensitivityKey = "receiver.soundSensitivity"

    // Menu and Settings
    private var menuButton: UIButton?
    private var menuOverlay: MenuOverlayView?
    private var settingsOverlay: SettingsOverlayView?
    private var savedToast: UILabel?

    // Line drawing - remote (right) video
    private let remoteDrawingLayer = CAShapeLayer()
    private var remoteLineStart: CGPoint?
    private var remoteLineEnd: CGPoint?
    private var remoteClearButton: UIButton?

    // Line drawing - front (left) video
    private let frontDrawingLayer = CAShapeLayer()
    private var frontLineStart: CGPoint?
    private var frontLineEnd: CGPoint?
    private var frontClearButton: UIButton?

    // Track which view is being drawn on
    private var activeDrawingView: UIView?
    private var replayRepeatCount: Int = 1
    private var currentReplayIteration: Int = 0
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
        triggerModeControl?.addTarget(self, action: #selector(handleTriggerModeChanged), for: .valueChanged)
        sensitivitySlider?.addTarget(self, action: #selector(handleSensitivityChanged), for: .valueChanged)
        menuButton?.addTarget(self, action: #selector(handleMenuTapped), for: .touchUpInside)
        setupAudioDetector()
        restoreTriggerModeSettings()
        loadReplaySettings()
        isRemoteMirrored = UserDefaults.standard.bool(forKey: remoteMirrorKey)
        remoteMirrorApplied = false
        syncRemoteMirrorUI(persist: false)
        if UserDefaults.standard.object(forKey: localMirrorKey) != nil {
            isLocalMirrored = UserDefaults.standard.bool(forKey: localMirrorKey)
        }
        syncLocalMirrorUI(persist: false)
        applyLocalMirrorTransform()

        // Start connection timer immediately
        startConnectionTimer()
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
        audioDetector.stop()
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

        // Sound trigger mode segmented control with icons
        let handIcon = UIImage(systemName: "hand.tap.fill")
        let micIcon = UIImage(systemName: "mic.fill")
        let modeControl = UISegmentedControl(items: [handIcon as Any, micIcon as Any])
        modeControl.selectedSegmentIndex = 0
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        modeControl.selectedSegmentTintColor = UIColor.systemBlue.withAlphaComponent(0.8)
        frontContainer.addSubview(modeControl)
        triggerModeControl = modeControl

        // Sensitivity controls container (hidden by default)
        let sensContainer = UIStackView()
        sensContainer.axis = .horizontal
        sensContainer.spacing = 8
        sensContainer.alignment = .center
        sensContainer.translatesAutoresizingMaskIntoConstraints = false
        sensContainer.isHidden = true

        let sensLabel = UILabel()
        sensLabel.text = "Med"
        sensLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sensLabel.textColor = .white
        sensLabel.textAlignment = .center
        sensLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true
        sensitivityLabel = sensLabel

        let slider = UISlider()
        slider.minimumValue = 0.0
        slider.maximumValue = 1.0
        slider.value = 0.5
        slider.tintColor = .systemBlue
        slider.translatesAutoresizingMaskIntoConstraints = false

        sensContainer.addArrangedSubview(slider)
        sensContainer.addArrangedSubview(sensLabel)
        frontContainer.addSubview(sensContainer)
        sensitivitySlider = slider
        sensitivityContainer = sensContainer

        frontContainer.addSubview(replayButton)

        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: frontContainer.leadingAnchor, constant: 12),
            modeControl.bottomAnchor.constraint(equalTo: frontContainer.bottomAnchor, constant: -12),

            sensContainer.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 8),
            sensContainer.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            sensContainer.trailingAnchor.constraint(lessThanOrEqualTo: frontContainer.trailingAnchor, constant: -12),
            slider.widthAnchor.constraint(equalToConstant: 80),

            replayButton.widthAnchor.constraint(equalToConstant: 56),
            replayButton.heightAnchor.constraint(equalToConstant: 56),
            replayButton.leadingAnchor.constraint(equalTo: frontContainer.leadingAnchor, constant: 12),
            replayButton.bottomAnchor.constraint(equalTo: modeControl.topAnchor, constant: -8)
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

        // Setup MPC video fallback image view (hidden by default)
        let mpcImageView = UIImageView()
        mpcImageView.translatesAutoresizingMaskIntoConstraints = false
        mpcImageView.contentMode = .scaleAspectFit
        mpcImageView.backgroundColor = .black
        mpcImageView.isHidden = true
        remoteContainer.addSubview(mpcImageView)
        NSLayoutConstraint.activate([
            mpcImageView.leadingAnchor.constraint(equalTo: remoteContainer.leadingAnchor),
            mpcImageView.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor),
            mpcImageView.topAnchor.constraint(equalTo: remoteContainer.topAnchor),
            mpcImageView.bottomAnchor.constraint(equalTo: remoteContainer.bottomAnchor)
        ])
        mpcVideoImageView = mpcImageView

        // Add connection status label centered on remote video
        let statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.numberOfLines = 2
        statusLabel.text = "  Waiting for sender...  "
        remoteContainer.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: remoteContainer.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: remoteContainer.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: remoteContainer.widthAnchor, multiplier: 0.9)
        ])
        connectionStatusLabel = statusLabel

        // Menu button (burger) - bottom right of remote container
        let menuBtn = UIButton(type: .system)
        let menuConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        menuBtn.setImage(UIImage(systemName: "line.3.horizontal", withConfiguration: menuConfig), for: .normal)
        menuBtn.tintColor = .white
        menuBtn.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        menuBtn.layer.cornerRadius = 18
        menuBtn.translatesAutoresizingMaskIntoConstraints = false
        menuBtn.accessibilityIdentifier = "menuButton"
        remoteContainer.addSubview(menuBtn)
        NSLayoutConstraint.activate([
            menuBtn.widthAnchor.constraint(equalToConstant: 36),
            menuBtn.heightAnchor.constraint(equalToConstant: 36),
            menuBtn.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor, constant: -12),
            menuBtn.bottomAnchor.constraint(equalTo: remoteContainer.bottomAnchor, constant: -12)
        ])
        menuButton = menuBtn

        // Bring buttons to front so they're not covered by MPC video or status label
        remoteContainer.bringSubviewToFront(remoteFlipButton)
        remoteContainer.bringSubviewToFront(menuBtn)

        // Drawing layer setup
        setupDrawingLayer()

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

        frontCameraQueue.async { [weak self] in
            guard let self = self, !self.isConfiguringFrontCamera else { return }
            self.isConfiguringFrontCamera = true
            defer { self.isConfiguringFrontCamera = false }
            do {
                let session = AVCaptureSession()
                session.beginConfiguration()
                session.sessionPreset = .medium

                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                }

                let dataOutput = AVCaptureVideoDataOutput()
                dataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
                dataOutput.alwaysDiscardsLateVideoFrames = true
                dataOutput.setSampleBufferDelegate(self, queue: self.frontCaptureOutputQueue)
                if session.canAddOutput(dataOutput) {
                    session.addOutput(dataOutput)
                }

                session.commitConfiguration()

                self.frontCameraSession = session
                self.frontCameraOutput = dataOutput

                if !session.isRunning {
                    session.startRunning()
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    let previewLayer = self.frontPreviewView.previewLayer
                    previewLayer.session = session
                    previewLayer.videoGravity = .resizeAspectFill
                    previewLayer.frame = self.frontPreviewView.bounds
                    previewLayer.needsDisplayOnBoundsChange = true

                    if let label = self.frontPreviewContainer?.subviews.compactMap({ $0 as? UILabel }).first {
                        self.frontPreviewContainer?.bringSubviewToFront(label)
                    }
                    self.frontPreviewContainer?.bringSubviewToFront(self.replayButton)

                    self.frontPreviewView.isHidden = false
                    self.frontPreviewContainer?.isHidden = false

                    self.updateFrontPreviewOrientation()
                    self.applyLocalMirrorTransform()
                    self.updateReplayTargetSizes()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    debugVideo("Failed to configure front camera preview: \(error.localizedDescription)")
                    self?.frontPreviewContainer?.isHidden = true
                }
            }
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

        // Save immediately on capture - don't wait for slow-mo replay to finish
        saveSwingAsync()

        isReplaying = true
        replayButton.isEnabled = false
        currentReplayIteration = 1  // Starting first iteration

        let hasRemoteReplay = !remoteReplaySequence.frames.isEmpty
        let hasFrontReplay = !frontReplaySequence.frames.isEmpty

        // Hide both WebRTC and MPC video views during replay
        remoteVideoView.isHidden = hasRemoteReplay
        mpcVideoImageView?.isHidden = hasRemoteReplay
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
            // Check if we need more iterations
            if currentReplayIteration < replayRepeatCount {
                currentReplayIteration += 1
                restartReplayIteration()
            } else {
                stopReplay()
            }
        }
    }

    private func restartReplayIteration() {
        // Reset sequences to beginning
        remoteReplaySequence.currentIndex = 0
        frontReplaySequence.currentIndex = 0
        // Reset timestamp to start timing from now
        replayStartTimestamp = CACurrentMediaTime()
        // Show first frames
        if let firstRemote = remoteReplaySequence.frames.first {
            remoteReplayImageView.image = firstRemote.image
        }
        if let firstFront = frontReplaySequence.frames.first {
            frontReplayImageView.image = firstFront.image
        }
        debugVideo("Replay iteration \(currentReplayIteration) of \(replayRepeatCount)")
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
        // Restore correct video view based on whether we're using MPC or WebRTC
        if usingMPCVideo {
            mpcVideoImageView?.isHidden = false
            remoteVideoView.isHidden = true
        } else {
            remoteVideoView.isHidden = false
            mpcVideoImageView?.isHidden = true
        }
        frontPreviewView.isHidden = false
        isReplaying = false
        replayButton.isEnabled = true

        // Note: Saving now happens at start of replay in saveSwingAsync()
        // Sequences are kept for replay iterations, reset not needed until next capture
    }

    /// Save swing asynchronously - called immediately when capture triggers
    private func saveSwingAsync() {
        // Capture references to frame arrays (these are value types, cheap to copy reference)
        let remoteFrameEntries = remoteReplaySequence.frames
        let frontFrameEntries = frontReplaySequence.frames

        guard !remoteFrameEntries.isEmpty else { return }

        // Capture line data on main thread (needs UI container sizes)
        var remoteLineData: LineData? = nil
        if let start = remoteLineStart, let end = remoteLineEnd, let container = remoteVideoContainer {
            remoteLineData = LineData(start: start, end: end, viewSize: container.bounds.size)
        }
        var frontLineData: LineData? = nil
        if let start = frontLineStart, let end = frontLineEnd, let container = frontPreviewView.superview {
            frontLineData = LineData(start: start, end: end, viewSize: container.bounds.size)
        }

        // Move frame extraction to background to avoid blocking replay
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let remoteFrames = remoteFrameEntries.map { $0.image }
            let frontFrames = frontFrameEntries.isEmpty ? nil : frontFrameEntries.map { $0.image }

            // Save in background - doesn't block replay
            SwingStorage.shared.saveSwing(
                remoteFrames: remoteFrames,
                frontFrames: frontFrames,
                remoteLine: remoteLineData,
                frontLine: frontLineData
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.showSavedToast()
                    case .failure(let error):
                        print("Failed to save swing: \(error.localizedDescription)")
                    }
                }
            }
        }
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
        let transform = CGAffineTransform(scaleX: scaleX, y: 1)
        remoteView.transform = transform
        mpcVideoImageView?.transform = transform  // Also apply to MPC video view
        remoteMirrorApplied = true
        return true
    }

    @objc private func handleLocalFlipTapped() {
        isLocalMirrored.toggle()
        syncLocalMirrorUI(persist: true)
        applyLocalMirrorTransform()
        frontReplayBuffer.clear()
    }

    // MARK: - Sound Trigger Mode

    private func setupAudioDetector() {
        audioDetector.onImpactDetected = { [weak self] in
            guard let self = self else { return }
            // Only trigger if in sound mode and not already replaying
            guard self.triggerModeControl?.selectedSegmentIndex == 1, !self.isReplaying else { return }
            print("AudioImpactDetector: Triggering replay from sound detection")
            self.handleReplayButtonTapped()
        }
    }

    private func restoreTriggerModeSettings() {
        // Restore saved trigger mode
        let savedMode = UserDefaults.standard.integer(forKey: triggerModeKey)
        triggerModeControl?.selectedSegmentIndex = savedMode

        // Restore saved sensitivity
        let savedSensitivity = UserDefaults.standard.object(forKey: sensitivityKey) as? Float ?? 0.5
        sensitivitySlider?.value = savedSensitivity
        audioDetector.sensitivity = savedSensitivity
        updateSensitivityLabel(savedSensitivity)

        // Update UI and start detector if needed
        updateTriggerModeUI(mode: savedMode)
        if savedMode == 1 {
            requestMicrophoneAndStartDetection()
        }
    }

    @objc private func handleTriggerModeChanged() {
        guard let control = triggerModeControl else { return }
        let mode = control.selectedSegmentIndex
        UserDefaults.standard.set(mode, forKey: triggerModeKey)
        updateTriggerModeUI(mode: mode)

        if mode == 1 {
            // Sound mode - request mic permission and start detection
            requestMicrophoneAndStartDetection()
        } else {
            // Manual mode - stop detection
            audioDetector.stop()
        }
    }

    private func updateTriggerModeUI(mode: Int) {
        let isSoundMode = mode == 1
        sensitivityContainer?.isHidden = !isSoundMode

        // In sound mode, hide the manual replay button since it's automatic
        replayButton.isHidden = isSoundMode
    }

    private func requestMicrophoneAndStartDetection() {
        let permission = AVAudioSession.sharedInstance().recordPermission
        switch permission {
        case .granted:
            audioDetector.start()
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.audioDetector.start()
                    } else {
                        // Fall back to manual mode
                        self?.triggerModeControl?.selectedSegmentIndex = 0
                        self?.updateTriggerModeUI(mode: 0)
                        UserDefaults.standard.set(0, forKey: self?.triggerModeKey ?? "")
                    }
                }
            }
        case .denied:
            // Already denied - fall back to manual mode
            triggerModeControl?.selectedSegmentIndex = 0
            updateTriggerModeUI(mode: 0)
            UserDefaults.standard.set(0, forKey: triggerModeKey)
        @unknown default:
            break
        }
    }

    @objc private func handleSensitivityChanged() {
        guard let slider = sensitivitySlider else { return }
        let value = slider.value
        audioDetector.sensitivity = value
        UserDefaults.standard.set(value, forKey: sensitivityKey)
        updateSensitivityLabel(value)
    }

    private func updateSensitivityLabel(_ value: Float) {
        let text: String
        if value < 0.33 {
            text = "Low"
        } else if value < 0.67 {
            text = "Med"
        } else {
            text = "High"
        }
        sensitivityLabel?.text = text
    }

    // MARK: - Settings

    private func loadReplaySettings() {
        replayRepeatCount = SettingsOverlayView.replayRepeatCount
        slowMotionFactor = SettingsOverlayView.slowMotionFactor
    }

    // MARK: - Line Drawing

    private func setupDrawingLayer() {
        // Setup remote (right) video drawing
        if let remoteContainer = remoteVideoContainer {
            remoteDrawingLayer.strokeColor = UIColor.systemYellow.cgColor
            remoteDrawingLayer.lineWidth = 3.0
            remoteDrawingLayer.lineCap = .round
            remoteDrawingLayer.fillColor = nil
            remoteContainer.layer.addSublayer(remoteDrawingLayer)

            let clearBtn = makeClearButton()
            remoteContainer.addSubview(clearBtn)
            NSLayoutConstraint.activate([
                clearBtn.widthAnchor.constraint(equalToConstant: 32),
                clearBtn.heightAnchor.constraint(equalToConstant: 32),
                clearBtn.topAnchor.constraint(equalTo: remoteContainer.topAnchor, constant: 12),
                clearBtn.leadingAnchor.constraint(equalTo: remoteContainer.leadingAnchor, constant: 12)
            ])
            clearBtn.addTarget(self, action: #selector(clearRemoteLineTapped), for: .touchUpInside)
            remoteClearButton = clearBtn
        }

        // Setup front (left) video drawing
        if let frontContainer = frontPreviewView.superview {
            frontDrawingLayer.strokeColor = UIColor.systemYellow.cgColor
            frontDrawingLayer.lineWidth = 3.0
            frontDrawingLayer.lineCap = .round
            frontDrawingLayer.fillColor = nil
            frontContainer.layer.addSublayer(frontDrawingLayer)

            let clearBtn = makeClearButton()
            frontContainer.addSubview(clearBtn)
            NSLayoutConstraint.activate([
                clearBtn.widthAnchor.constraint(equalToConstant: 32),
                clearBtn.heightAnchor.constraint(equalToConstant: 32),
                clearBtn.topAnchor.constraint(equalTo: frontContainer.topAnchor, constant: 12),
                clearBtn.leadingAnchor.constraint(equalTo: frontContainer.leadingAnchor, constant: 12)
            ])
            clearBtn.addTarget(self, action: #selector(clearFrontLineTapped), for: .touchUpInside)
            frontClearButton = clearBtn
        }
    }

    private func makeClearButton() -> UIButton {
        let clearBtn = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        clearBtn.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        clearBtn.tintColor = .systemYellow
        clearBtn.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        clearBtn.layer.cornerRadius = 16
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.isHidden = true
        return clearBtn
    }

    @objc private func clearRemoteLineTapped() {
        remoteLineStart = nil
        remoteLineEnd = nil
        remoteDrawingLayer.path = nil
        remoteClearButton?.isHidden = true
    }

    @objc private func clearFrontLineTapped() {
        frontLineStart = nil
        frontLineEnd = nil
        frontDrawingLayer.path = nil
        frontClearButton?.isHidden = true
    }

    private func updateRemoteLine() {
        guard let start = remoteLineStart, let end = remoteLineEnd else {
            remoteDrawingLayer.path = nil
            return
        }
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        remoteDrawingLayer.path = path.cgPath
        remoteClearButton?.isHidden = false
    }

    private func updateFrontLine() {
        guard let start = frontLineStart, let end = frontLineEnd else {
            frontDrawingLayer.path = nil
            return
        }
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        frontDrawingLayer.path = path.cgPath
        frontClearButton?.isHidden = false
    }

    /// Returns current line data for saving with swing
    func getLineData() -> (remote: (start: CGPoint, end: CGPoint)?, front: (start: CGPoint, end: CGPoint)?) {
        let remoteLine: (CGPoint, CGPoint)? = (remoteLineStart != nil && remoteLineEnd != nil)
            ? (remoteLineStart!, remoteLineEnd!) : nil
        let frontLine: (CGPoint, CGPoint)? = (frontLineStart != nil && frontLineEnd != nil)
            ? (frontLineStart!, frontLineEnd!) : nil
        return (remoteLine, frontLine)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }

        // Check remote container - only if no line exists yet
        if let remoteContainer = remoteVideoContainer {
            let loc = touch.location(in: remoteContainer)
            if remoteContainer.bounds.contains(loc) && remoteLineStart == nil {
                remoteLineStart = loc
                remoteLineEnd = loc
                activeDrawingView = remoteContainer
                updateRemoteLine()
                return
            }
        }

        // Check front container - only if no line exists yet
        if let frontContainer = frontPreviewView.superview {
            let loc = touch.location(in: frontContainer)
            if frontContainer.bounds.contains(loc) && frontLineStart == nil {
                frontLineStart = loc
                frontLineEnd = loc
                activeDrawingView = frontContainer
                updateFrontLine()
                return
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let activeView = activeDrawingView else { return }

        if activeView == remoteVideoContainer {
            remoteLineEnd = touch.location(in: activeView)
            updateRemoteLine()
        } else if activeView == frontPreviewView.superview {
            frontLineEnd = touch.location(in: activeView)
            updateFrontLine()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = touches.first, let activeView = activeDrawingView else { return }

        if activeView == remoteVideoContainer {
            remoteLineEnd = touch.location(in: activeView)
            updateRemoteLine()
        } else if activeView == frontPreviewView.superview {
            frontLineEnd = touch.location(in: activeView)
            updateFrontLine()
        }
        activeDrawingView = nil
    }

    @objc private func handleMenuTapped() {
        let overlay = MenuOverlayView()
        overlay.delegate = self
        overlay.show(in: view)
        menuOverlay = overlay
    }

    private func showSettingsOverlay() {
        let overlay = SettingsOverlayView()
        overlay.delegate = self
        overlay.show(in: view)
        settingsOverlay = overlay
    }

    private func showSwingLibrary() {
        let libraryVC = SwingLibraryViewController()
        libraryVC.modalPresentationStyle = .fullScreen
        present(libraryVC, animated: true)
    }

    private func showSavedToast() {
        guard savedToast == nil else { return }

        let toast = UILabel()
        toast.text = "  Saved  "
        toast.font = .systemFont(ofSize: 14, weight: .semibold)
        toast.textColor = .white
        toast.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
        toast.layer.cornerRadius = 12
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.alpha = 0

        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)
        ])
        savedToast = toast

        UIView.animate(withDuration: 0.2) {
            toast.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.5, options: []) {
                toast.alpha = 0
            } completion: { _ in
                toast.removeFromSuperview()
                self.savedToast = nil
            }
        }
    }

    private func syncLocalMirrorUI(persist: Bool) {
        let title = isLocalMirrored ? "Local Unflip" : "Local Flip"
        localFlipButton.setTitle(title, for: .normal)
        if persist {
            UserDefaults.standard.set(isLocalMirrored, forKey: localMirrorKey)
        }
    }

    private func applyLocalMirrorTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let connection = frontPreviewView.previewLayer.connection {
            if connection.automaticallyAdjustsVideoMirroring {
                connection.automaticallyAdjustsVideoMirroring = false
            }
            if connection.isVideoOrientationSupported,
               connection.videoOrientation != currentPreviewOrientation {
                connection.videoOrientation = currentPreviewOrientation
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = isLocalMirrored
            }
        }
        CATransaction.commit()

        frontCameraQueue.async { [weak self] in
            guard let self = self,
                  let dataOutputConnection = self.frontCameraOutput?.connection(with: .video) else {
                return
            }

            if dataOutputConnection.automaticallyAdjustsVideoMirroring {
                dataOutputConnection.automaticallyAdjustsVideoMirroring = false
            }
            if dataOutputConnection.isVideoOrientationSupported,
               dataOutputConnection.videoOrientation != self.currentPreviewOrientation {
                dataOutputConnection.videoOrientation = self.currentPreviewOrientation
            }
            if dataOutputConnection.isVideoMirroringSupported {
                dataOutputConnection.isVideoMirrored = self.isLocalMirrored
            }
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
        // Handle incoming MPC video frames (H.264 encoded with rotation)
        signaler.onVideoFrame = { [weak self] h264Data, rotation in
            self?.handleMPCVideoFrame(h264Data, rotation: rotation)
        }

        // Setup H.264 decoder callback
        h264Decoder.onDecodedFrame = { [weak self] pixelBuffer in
            self?.handleDecodedFrame(pixelBuffer)
        }

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
                        optionalConstraints: ["CandidateNetworkPolicy": "low_cost"]
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
                debugCandidate("RECEIVER", direction: "RECEIVED", candidate: candidateSdp)
                let candidate = RTCIceCandidate(
                    sdp: candidateSdp,
                    sdpMLineIndex: sdpMLineIndex,
                    sdpMid: sdpMid
                )
                self.peerConnection.add(candidate) { error in
                    if let error = error {
                        debugICE("RECEIVER failed to add candidate: \(error)")
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
        debugICE("RECEIVER state → \(stateName)")

        if newState == .checking {
            startICEPairMonitoring()
            iceCheckingStarted = true
        } else if newState == .connected || newState == .completed {
            stopICEPairMonitoring()
            stopConnectionTimer()
            iceCheckingStarted = false
            debugICE("RECEIVER ✅ ICE connected successfully!")
            updateConnectionStatus("Connected via WebRTC", isConnected: true)
            // Disable MPC video since WebRTC is working
            if usingMPCVideo {
                disableMPCVideo()
            }
        } else if newState == .failed {
            stopICEPairMonitoring()
            stopConnectionTimer()
            iceCheckingStarted = false
            debugICE("RECEIVER ❌ ICE CONNECTION FAILED - waiting for MPC video")
            updateConnectionStatus("Waiting for peer-to-peer...")
            // MPC video will automatically be shown when frames arrive
        } else if newState == .disconnected {
            debugICE("RECEIVER ⚠️ ICE disconnected")
            updateConnectionStatus("Reconnecting...")
        }
    }

    // MARK: - MPC Video Fallback

    private func handleMPCVideoFrame(_ h264Data: Data, rotation: Int) {
        // First frame - enable MPC video display
        if !usingMPCVideo {
            enableMPCVideo()
        } else {
            // Already using MPC video - but ensure status is correct (fixes reconnection bug)
            // Only update if status label is visible (meaning it might show stale message)
            if connectionStatusLabel?.isHidden == false {
                stopConnectionTimer()
                updateConnectionStatus("Connected via peer-to-peer", isConnected: true)
            }
        }

        // Store rotation for use when decoded frame arrives
        currentMPCRotation = rotation

        // Decode H.264 NAL data (async, callback will handle display)
        h264Decoder.decode(nalData: h264Data)

        mpcFrameCount += 1

        // Log periodically
        if mpcFrameCount % 30 == 0 {
            print("Receiver: 📹 MPC received H.264 frame \(mpcFrameCount), size: \(h264Data.count) bytes, rot: \(rotation * 90)°")
        }
    }

    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        // Convert CVPixelBuffer to CIImage
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Apply rotation based on currentMPCRotation (0=0°, 1=90°, 2=180°, 3=270°)
        // CIImage rotation is counterclockwise, so we need to adjust
        switch currentMPCRotation {
        case 1: // 90° clockwise = 270° counterclockwise
            ciImage = ciImage.oriented(.right)
        case 2: // 180°
            ciImage = ciImage.oriented(.down)
        case 3: // 270° clockwise = 90° counterclockwise
            ciImage = ciImage.oriented(.left)
        default: // 0° - no rotation needed
            break
        }

        guard let cgImage = mpcCIContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)

        // Update the image view
        mpcVideoImageView?.image = image

        // Also add to replay buffer for slow-motion replay
        if !isReplaying {
            remoteReplayBuffer.append(image: image, timestamp: CACurrentMediaTime())
        }
    }

    private func enableMPCVideo() {
        usingMPCVideo = true
        mpcVideoImageView?.isHidden = false
        remoteVideoView?.isHidden = true
        stopConnectionTimer()
        updateConnectionStatus("Connected via peer-to-peer", isConnected: true)
        print("Receiver: 📹 MPC video fallback ENABLED - displaying via ImageView")
    }

    private func updateConnectionStatus(_ status: String, isConnected: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let label = self.connectionStatusLabel else { return }
            label.text = "  \(status)  "

            if isConnected {
                // Fade out after showing briefly
                UIView.animate(withDuration: 0.3, delay: 2.0, options: [], animations: {
                    label.alpha = 0
                }, completion: { _ in
                    label.isHidden = true
                    label.alpha = 1
                })
            } else {
                label.isHidden = false
                label.alpha = 1
            }
        }
    }

    private func startConnectionTimer() {
        connectionStartTime = Date()
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateConnectionTimerDisplay()
        }
        updateConnectionTimerDisplay()
    }

    private func stopConnectionTimer() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        connectionStartTime = nil
    }

    private func updateConnectionTimerDisplay() {
        guard let startTime = connectionStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(startTime))
        if iceCheckingStarted {
            updateConnectionStatus("Connecting... (\(elapsed)s)")
        } else {
            updateConnectionStatus("Waiting for sender... (\(elapsed)s)")
        }
    }

    private func disableMPCVideo() {
        usingMPCVideo = false
        mpcVideoImageView?.isHidden = true
        remoteVideoView?.isHidden = false
        print("Receiver: 📹 MPC video fallback DISABLED - WebRTC connected")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Receiver: ICE gathering → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        debugCandidate("RECEIVER", direction: "GENERATED", candidate: candidate.sdp)
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

    // MARK: - ICE Pair Monitoring

    private var icePairTimer: Timer?

    private func startICEPairMonitoring() {
        guard DebugFlags.icePairChecks else { return }
        DispatchQueue.main.async { [weak self] in
            self?.icePairTimer?.invalidate()
            self?.icePairTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.logICECandidatePairs()
            }
            // Fire immediately once
            self?.logICECandidatePairs()
        }
    }

    private func stopICEPairMonitoring() {
        icePairTimer?.invalidate()
        icePairTimer = nil
    }

    private func logICECandidatePairs() {
        guard DebugFlags.icePairChecks, peerConnection != nil else { return }

        peerConnection.statistics { [weak self] stats in
            guard self != nil else { return }

            var pairs: [(state: String, local: String, remote: String, nominated: Bool, bytesSent: UInt64, bytesRecv: UInt64)] = []

            // First pass: collect candidate info - use stat.id as key (not values["id"])
            var candidateInfo: [String: String] = [:]
            for (statId, stat) in stats.statistics {
                if stat.type == "local-candidate" || stat.type == "remote-candidate" {
                    let ip = stat.values["address"] as? String ?? stat.values["ip"] as? String ?? "?"
                    let port = stat.values["port"] as? Int ?? 0
                    let proto = stat.values["protocol"] as? String ?? "?"
                    let candidateType = stat.values["candidateType"] as? String ?? "?"
                    candidateInfo[statId] = "\(candidateType) \(ip):\(port) (\(proto))"
                }
            }

            // Second pass: collect pairs
            for stat in stats.statistics.values {
                if stat.type == "candidate-pair" {
                    let state = stat.values["state"] as? String ?? "?"
                    let nominated = stat.values["nominated"] as? Bool ?? false
                    let localId = stat.values["localCandidateId"] as? String ?? ""
                    let remoteId = stat.values["remoteCandidateId"] as? String ?? ""
                    let bytesSent = (stat.values["bytesSent"] as? NSNumber)?.uint64Value ?? 0
                    let bytesRecv = (stat.values["bytesReceived"] as? NSNumber)?.uint64Value ?? 0

                    let localDesc = candidateInfo[localId] ?? localId
                    let remoteDesc = candidateInfo[remoteId] ?? remoteId

                    pairs.append((state, localDesc, remoteDesc, nominated, bytesSent, bytesRecv))
                }
            }

            // Log summary
            if pairs.isEmpty {
                debugICEPairs("RECEIVER ICE: No candidate pairs yet")
                return
            }

            let inProgress = pairs.filter { $0.state == "in-progress" }.count
            let succeeded = pairs.filter { $0.state == "succeeded" }.count
            let failed = pairs.filter { $0.state == "failed" }.count
            let waiting = pairs.filter { $0.state == "waiting" }.count
            let frozen = pairs.filter { $0.state == "frozen" }.count

            debugICEPairs("RECEIVER ICE: \(pairs.count) pairs - succeeded:\(succeeded) in-progress:\(inProgress) waiting:\(waiting) frozen:\(frozen) failed:\(failed)")

            // Log active/interesting pairs
            for pair in pairs where pair.state == "in-progress" || pair.state == "succeeded" {
                let marker = pair.nominated ? "★" : " "
                debugICEPairs("  \(marker) [\(pair.state)] local:\(pair.local) ↔ remote:\(pair.remote) sent:\(pair.bytesSent) recv:\(pair.bytesRecv)")
            }

            // Log failed pairs to understand why
            if failed > 0 && succeeded == 0 {
                debugICEPairs("  ⚠️ Failed pairs:")
                for pair in pairs.prefix(5) where pair.state == "failed" {
                    debugICEPairs("    ✗ local:\(pair.local) ↔ remote:\(pair.remote)")
                }
            }
        }
    }

    private func logWebRTCStats() {
        guard peerConnection != nil else { return }

        peerConnection.statistics { [weak self] stats in
            guard let self = self else { return }

            let shouldLogICE = DebugFlags.iceDetailed
            let shouldLogStats = DebugFlags.webrtcStats
            guard shouldLogICE || shouldLogStats else { return }

            let currentTime = Date()
            let timeDiff = currentTime.timeIntervalSince(self.lastStatsTime)
            self.lastStatsTime = currentTime

            if shouldLogStats {
                print("📊 RECEIVER WEBRTC STATS (Δ\(String(format: "%.1f", timeDiff))s):")
            }

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
                if shouldLogICE, stat.type == "candidate-pair" {
                    let state = stat.values["state"] as? String ?? "?"
                    if state == "succeeded" || state == "in-progress" {
                        let pairId = stat.values["id"].map { String(describing: $0) } ?? "?"
                        let nominated = stat.values["nominated"].map { String(describing: $0) } ?? "?"
                        let localType = stat.values["localCandidateType"].map { String(describing: $0) } ?? "?"
                        let remoteType = stat.values["remoteCandidateType"].map { String(describing: $0) } ?? "?"
                        print("  Pair \(pairId): state=\(state) nominated=\(nominated) local=\(localType) remote=\(remoteType)")

                        if let localId = stat.values["localCandidateId"] as? String,
                           let local = stats.statistics[localId]?.values {
                            print("    ↳ localId=\(localId) data=\(local)")
                        }
                        if let remoteId = stat.values["remoteCandidateId"] as? String,
                           let remote = stats.statistics[remoteId]?.values {
                            print("    ↳ remoteId=\(remoteId) data=\(remote)")
                        }
                        print("    ↳ raw: \(stat.values)")
                    }
                }

                // Inbound RTP (what we're receiving)
                if shouldLogStats,
                   stat.type == "inbound-rtp" && stat.values["mediaType"] as? String == "video" {
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
                if shouldLogStats, stat.type == "candidate-pair" && stat.values["state"] as? String == "succeeded" {
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

// MARK: - SettingsOverlayDelegate

extension ReceiverViewController: SettingsOverlayDelegate {
    func settingsDidChange() {
        loadReplaySettings()
    }

    func settingsDidClose() {
        settingsOverlay = nil
    }
}

// MARK: - MenuOverlayDelegate

extension ReceiverViewController: MenuOverlayDelegate {
    func menuDidSelectSettings() {
        showSettingsOverlay()
    }

    func menuDidSelectVideoLibrary() {
        showSwingLibrary()
    }

    func menuDidClose() {
        menuOverlay = nil
    }
}
