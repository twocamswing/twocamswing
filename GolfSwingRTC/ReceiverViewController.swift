import UIKit
import WebRTC
import MultipeerConnectivity
import Foundation
import AVFoundation

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

final class ReceiverViewController: UIViewController, RTCPeerConnectionDelegate {
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
    private let frontCameraQueue = DispatchQueue(label: "com.golfswingrtc.receiver.frontcamera")

    // Statistics tracking
    private var statsTimer: Timer?
    private var lastStatsTime = Date()
    private var bytesReceivedLastCheck: UInt64 = 0
    private var packetsReceivedLastCheck: UInt32 = 0

    deinit {
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

            session.commitConfiguration()

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

            frontPreviewView.isHidden = false
            frontPreviewContainer?.isHidden = false

            frontCameraSession = session

            startFrontCameraSessionIfNeeded()
            updateFrontPreviewOrientation()
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
        guard let connection = frontPreviewView.previewLayer.connection,
              connection.isVideoOrientationSupported,
              connection.videoOrientation != orientation else { return }
        connection.videoOrientation = orientation
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

                // Don't apply rotation transforms - just use proper content mode
                self.handleVideoRotation(track: track)

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
