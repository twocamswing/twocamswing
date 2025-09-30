import UIKit
import AVFoundation
import WebRTC

final class SenderViewController: UIViewController, RTCPeerConnectionDelegate, RTCVideoCapturerDelegate {

    // MARK: - WebRTC
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection!
    private var videoSource: RTCVideoSource!
    private var capturer: RTCCameraVideoCapturer!
    private var localVideoTrack: RTCVideoTrack?

    // MARK: - Signaling
    private let signaler = MPCSignaler(role: .advertiser)
    private var pendingCandidates: [RTCIceCandidate] = []

    // MARK: - UI
    private var preview: RTCMTLVideoView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebRTC()
        setupPreview()
        setupSignaling()
        startCapture()
        makeOffer()
    }

    // MARK: - Setup

    private func setupWebRTC() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        // Use multiple STUN servers for better connectivity
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun2.l.google.com:19302"])
        ]
        config.iceTransportPolicy = .all
        config.bundlePolicy = .balanced
        config.rtcpMuxPolicy = .require
        config.iceCandidatePoolSize = 2
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        videoSource = factory.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: videoSource)

        // Also set ourselves as delegate to monitor frame capture
        capturer.delegate = self

        // DON'T create video track yet - wait until capture starts and video source is live
        // localVideoTrack will be created after capture starts
        print("Sender: Video track creation deferred until capture starts")
    }

    private func setupPreview() {
        preview = RTCMTLVideoView(frame: view.bounds)
        preview.videoContentMode = .scaleAspectFill
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.backgroundColor = .blue // Debug color to verify view is there
        view.addSubview(preview)

        print("Sender: setupPreview - preview frame: \(preview.frame)")
        print("Sender: setupPreview - preview created, video track will be created and attached after capture starts")
    }

    private func setupSignaling() {
        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }

            switch msg {
            case .answer(let sdpText):
                let answer = RTCSessionDescription(type: .answer, sdp: sdpText)
                self.peerConnection.setRemoteDescription(answer) { error in
                    if let error = error {
                        print("Sender: failed to set remote answer: \(error)")
                        return
                    }
                    self.applyPendingCandidates()
                }

            case .candidate(let candSdp, let sdpMid, let sdpMLineIndex):
                let cand = RTCIceCandidate(
                    sdp: candSdp,
                    sdpMLineIndex: sdpMLineIndex,
                    sdpMid: sdpMid
                )
                if self.peerConnection.remoteDescription != nil {
                    self.peerConnection.add(cand) { error in
                        if let error = error {
                            print("Sender: failed to add candidate: \(error)")
                        } else {
                            print("Sender: applied candidate successfully")
                        }
                    }
                } else {
                    self.pendingCandidates.append(cand)
                    print("Sender: queued candidate")
                }

            case .offer:
                // sender never expects an offer
                break
            }
        }
    }

    // MARK: - Capture

    private func startCapture() {
        print("Sender: Requesting camera access...")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                print("Sender: Camera access granted: \(granted)")
                guard granted else {
                    print("Sender: Camera access denied!")
                    return
                }

                let devices = RTCCameraVideoCapturer.captureDevices()
                print("Sender: Found \(devices.count) capture devices")

                guard let device = devices.first(where: { $0.position == .back }) ?? devices.first else {
                    print("Sender: No camera device found!")
                    return
                }

                print("Sender: Selected device: \(device.localizedName) (position: \(device.position.rawValue))")

                let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
                print("Sender: Device supports \(formats.count) formats")

                // Select a reasonable resolution for WebRTC streaming (prefer 720p-1080p range)
                let format = formats.first { format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let pixels = dimensions.width * dimensions.height
                    return pixels >= 1280 * 720 && pixels <= 1920 * 1080 // 720p to 1080p range
                } ?? formats.first { format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return dimensions.width >= 640 && dimensions.height >= 480 // fallback to VGA+
                } ?? formats.first!

                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                print("Sender: Selected format: \(dimensions.width)x\(dimensions.height)")

                let maxFps = Int(format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30)
                let fps = max(24, min(60, maxFps))
                print("Sender: Using FPS: \(fps)")

                print("Sender: Starting video capture...")
                self.capturer.startCapture(with: device, format: format, fps: fps)
                self.isCapturerRunning = true
                self.lastFrameTime = Date()

                print("Sender: Video source state: \(String(describing: self.videoSource))")
                print("Sender: Video track will be created after capture stabilizes")

                // Wait a moment for first frame to arrive, then create fresh video track with live source
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print("Sender: Creating fresh video track with live source...")

                    // Create new video track with live video source
                    self.localVideoTrack = self.factory.videoTrack(with: self.videoSource, trackId: "video0")

                    guard let track = self.localVideoTrack else {
                        print("Sender: Failed to create video track!")
                        return
                    }

                    print("Sender: Fresh video track created")
                    print("Sender: Video track ID: \(track.trackId)")
                    print("Sender: Video track enabled at creation: \(track.isEnabled)")
                    print("Sender: Video track ready state at creation: \(track.readyState.rawValue)")

                    // Attach to preview immediately after track creation
                    print("Sender: Attaching fresh video track to preview...")
                    track.add(self.preview)
                    print("Sender: Video track attached to preview")

                    // Enable the track explicitly
                    track.isEnabled = true
                    print("Sender: Video track explicitly enabled: \(track.isEnabled)")

                    print("Sender: Adding fresh video track to peer connection...")
                    let sender = self.peerConnection.add(track, streamIds: ["stream0"])
                    print("Sender: Added video track to peer connection, sender: \(sender?.track?.kind ?? "nil")")
                    print("Sender: Video track ready state after add: \(track.readyState.rawValue)")
                    print("Sender: RTP sender parameters: \(sender?.parameters ?? RTCRtpParameters())")

                    // Force renegotiation now that we have a live video track
                    self.peerConnection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, error in
                        guard let self = self, let sdp = sdp, error == nil else {
                            print("Sender: Failed to create offer after adding track: \(error?.localizedDescription ?? "unknown")")
                            return
                        }

                        self.peerConnection.setLocalDescription(sdp) { error in
                            if let error = error {
                                print("Sender: Failed to set local description: \(error.localizedDescription)")
                                return
                            }
                            print("Sender: setLocalDescription(offer) ok after adding track")
                            print("Sender: Offer SDP contains video: \(sdp.sdp.contains("m=video"))")
                            self.signaler.send(.offer(sdp))
                            print("Sender: sent renegotiation offer")
                        }
                    }
                }

                // Verify and maintain video pipeline with periodic checks
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("Sender: Verifying video pipeline after 2 seconds...")
                    self.checkAndMaintainVideoTrack()
                }

                // Start periodic video track maintenance every 5 seconds
                Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
                    guard let self = self else {
                        timer.invalidate()
                        return
                    }
                    self.checkAndMaintainVideoTrack()
                }

                // Start WebRTC statistics monitoring every 2 seconds
                self.statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                    guard let self = self else {
                        timer.invalidate()
                        return
                    }
                    self.logWebRTCStats()
                }
            }
        }
    }

    // MARK: - Video Track Maintenance

    private var lastFrameTime = Date()
    private var frameCount = 0
    private var isCapturerRunning = false
    private var statsTimer: Timer?
    private var lastStatsTime = Date()
    private var bytesSentLastCheck: UInt64 = 0
    private var packetsSentLastCheck: UInt32 = 0

    private func checkAndMaintainVideoTrack() {
        guard let localVideoTrack = localVideoTrack else {
            print("Sender: Video track maintenance check - no track created yet")
            return
        }

        print("Sender: Video track maintenance check...")
        print("Sender: Video track enabled: \(localVideoTrack.isEnabled)")
        print("Sender: Video track ready state: \(localVideoTrack.readyState.rawValue)")
        print("Sender: Video source state: \(String(describing: videoSource))")

        // Check if we've received frames recently
        let timeSinceLastFrame = Date().timeIntervalSince(lastFrameTime)
        print("Sender: Time since last frame: \(timeSinceLastFrame)s, Frame count: \(frameCount)")

        // If no frames for more than 6 seconds, restart capture
        if timeSinceLastFrame > 6.0 && isCapturerRunning {
            print("Sender: No frames received for \(timeSinceLastFrame)s - restarting capture")
            restartVideoCapture()
            return
        }

        // If track is not enabled or not in live state, fix it
        if !localVideoTrack.isEnabled {
            print("Sender: Video track was disabled, re-enabling...")
            localVideoTrack.isEnabled = true
        }

        if localVideoTrack.readyState.rawValue == 0 {
            print("Sender: Video track ready state is 0, attempting to reactivate...")
            // Try to reattach the video track to refresh its state
            localVideoTrack.remove(preview)
            localVideoTrack.add(preview)
            localVideoTrack.isEnabled = true
            print("Sender: Video track reattached and re-enabled")
        }

        // Force preview refresh
        preview.setNeedsLayout()
        preview.layoutIfNeeded()
        view.bringSubviewToFront(preview)
    }

    private func restartVideoCapture() {
        print("Sender: Restarting video capture...")

        // Stop current capture
        capturer.stopCapture()
        isCapturerRunning = false

        // Wait a moment then restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.reinitializeVideoCapture()
        }
    }

    private func reinitializeVideoCapture() {
        print("Sender: Reinitializing video capture...")

        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .back }) ?? devices.first else {
            print("Sender: No camera device found during restart!")
            return
        }

        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = dimensions.width * dimensions.height
            return pixels >= 1280 * 720 && pixels <= 1920 * 1080
        } ?? formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= 640 && dimensions.height >= 480
        } ?? formats.first!

        let fps = max(24, min(30, Int(format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30)))

        print("Sender: Restarting capture with format: \(CMVideoFormatDescriptionGetDimensions(format.formatDescription).width)x\(CMVideoFormatDescriptionGetDimensions(format.formatDescription).height) @ \(fps)fps")

        capturer.startCapture(with: device, format: format, fps: fps)
        isCapturerRunning = true

        // Reset frame tracking
        lastFrameTime = Date()
        frameCount = 0

        // Re-enable track if it exists
        localVideoTrack?.isEnabled = true
        print("Sender: Video capture restarted successfully")
    }

    // MARK: - WebRTC Statistics and Diagnostics

    private func logWebRTCStats() {
        guard peerConnection != nil else { return }

        peerConnection.statistics { [weak self] stats in
            guard let self = self else { return }

            let currentTime = Date()
            let timeDiff = currentTime.timeIntervalSince(self.lastStatsTime)
            self.lastStatsTime = currentTime

            print("🔍 SENDER WEBRTC STATS (Δ\(String(format: "%.1f", timeDiff))s):")

            var videoSent: UInt64 = 0
            var audioSent: UInt64 = 0
            var packetsSent: UInt32 = 0
            var packetsLost: UInt32 = 0
            var bytesSent: UInt64 = 0
            var framesPerSecond: Double = 0
            var frameWidth: UInt32 = 0
            var frameHeight: UInt32 = 0
            var encoderImplementation = "unknown"
            var bitrateMbps: Double = 0

            for stat in stats.statistics.values {
                // Outbound RTP (what we're sending)
                if stat.type == "outbound-rtp" && stat.values["mediaType"] as? String == "video" {
                    if let bytes = stat.values["bytesSent"] as? UInt64 {
                        bytesSent = bytes
                        videoSent = bytes
                    }
                    if let packets = stat.values["packetsSent"] as? UInt32 {
                        packetsSent = packets
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
                    if let impl = stat.values["encoderImplementation"] as? String {
                        encoderImplementation = impl
                    }
                }

                // Candidate pair (connection quality)
                if stat.type == "candidate-pair" && stat.values["state"] as? String == "succeeded" {
                    if let rtt = stat.values["currentRoundTripTime"] as? Double {
                        print("  📡 RTT: \(String(format: "%.0f", rtt * 1000))ms")
                    }
                    if let available = stat.values["availableOutgoingBitrate"] as? Double {
                        print("  📊 Available outgoing: \(String(format: "%.1f", available / 1000000))Mbps")
                    }
                }

                // Media source (frame statistics)
                if stat.type == "media-source" && stat.values["kind"] as? String == "video" {
                    if let fps = stat.values["framesPerSecond"] as? Double {
                        print("  🎥 Source FPS: \(String(format: "%.1f", fps))")
                    }
                    if let width = stat.values["width"] as? UInt32,
                       let height = stat.values["height"] as? UInt32 {
                        print("  📐 Source resolution: \(width)x\(height)")
                    }
                }
            }

            // Calculate bitrate
            let bytesDiff = bytesSent - self.bytesSentLastCheck
            let packetsDiff = packetsSent - self.packetsSentLastCheck
            bitrateMbps = (Double(bytesDiff) * 8.0) / (timeDiff * 1000000.0)

            print("  📤 Bytes sent: \(bytesSent) (Δ\(bytesDiff))")
            print("  📦 Packets sent: \(packetsSent) (Δ\(packetsDiff)), lost: \(packetsLost)")
            print("  🎬 Encoded: \(frameWidth)x\(frameHeight) @ \(String(format: "%.1f", framesPerSecond))fps")
            print("  💾 Encoder: \(encoderImplementation)")
            print("  🚀 Bitrate: \(String(format: "%.2f", bitrateMbps))Mbps")

            // Update for next calculation
            self.bytesSentLastCheck = bytesSent
            self.packetsSentLastCheck = packetsSent

            // Health checks
            if framesPerSecond < 5.0 && framesPerSecond > 0 {
                print("  ⚠️ WARNING: Low FPS (\(framesPerSecond)) - encoding issues?")
            }

            if bitrateMbps < 0.1 && bytesDiff == 0 && timeDiff > 3.0 {
                print("  🚨 CRITICAL: No bytes sent in \(String(format: "%.1f", timeDiff))s - stream may be frozen!")
            }

            if packetsLost > 0 {
                print("  ⚠️ WARNING: \(packetsLost) packets lost - network issues?")
            }
        }
    }

    // MARK: - Offer / ICE

    private func makeOffer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo":"false"],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] sdp, err in
            guard let self = self, let sdp = sdp, err == nil else {
                print("Sender: offer error \(String(describing: err))")
                return
            }
            self.peerConnection.setLocalDescription(sdp) { err in
                print("Sender: setLocalDescription(offer) \(err?.localizedDescription ?? "ok")")
            }
            print("Sender: Offer SDP contains video: \(sdp.sdp.contains("m=video"))")
            print("Sender: Offer SDP video lines: \(sdp.sdp.components(separatedBy: "\n").filter { $0.contains("video") }.count)")
            self.signaler.send(SignalMessage.offer(sdp))
            print("Sender: sent offer")
        }
    }

    private func applyPendingCandidates() {
        for c in pendingCandidates {
            peerConnection.add(c) { error in
                if let error = error {
                    print("Sender: failed to add pending candidate: \(error)")
                } else {
                    print("Sender: applied pending candidate")
                }
            }
        }
        pendingCandidates.removeAll()
    }

    private func restartIce() {
        print("Sender: Restarting ICE...")
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo":"false", "IceRestart":"true"],
            optionalConstraints: nil
        )
        peerConnection.offer(for: constraints) { [weak self] sdp, err in
            guard let self = self, let sdp = sdp, err == nil else {
                print("Sender: ICE restart offer error \(String(describing: err))")
                return
            }
            self.peerConnection.setLocalDescription(sdp) { err in
                print("Sender: ICE restart setLocalDescription(offer) \(err?.localizedDescription ?? "ok")")
            }
            self.signaler.send(SignalMessage.offer(sdp))
            print("Sender: sent ICE restart offer")
        }
    }

    // MARK: - RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Sender: signaling → \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("Sender: should negotiate")
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
        print("Sender: ICE state → \(stateName) (\(newState.rawValue))")

        if newState == .failed {
            print("Sender: ICE CONNECTION FAILED - attempting to restart")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.restartIce()
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Sender: ICE gathering → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let candidateString = candidate.sdp
        print("Sender: generated candidate: \(candidateString.prefix(60))...")
        signaler.send(SignalMessage.candidate(candidate))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // MARK: - RTCVideoCapturerDelegate

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        frameCount += 1
        lastFrameTime = Date()

        // Log every 30 frames to avoid spam
        if frameCount % 30 == 0 {
            print("Sender: Captured frame \(frameCount), size: \(frame.width)x\(frame.height)")
        }

        // Forward to video source
        videoSource.capturer(capturer, didCapture: frame)
    }

}
