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
    private var hasSentInitialOffer = false
    private var isPreviewAttached = false

    // MARK: - Signaling
    private let signaler = MPCSignaler(role: .advertiser)
    private var pendingCandidates: [RTCIceCandidate] = []

    // MARK: - MPC Video Fallback
    private var useMPCVideo = false  // Set to true when WebRTC ICE fails
    private var mpcFrameCount = 0
    private let mpcTargetFPS: Double = 30  // Target 30 FPS for smooth video
    private var lastMPCFrameTime: TimeInterval = 0
    private var iceCheckingStartTime: Date?
    private let iceTimeoutSeconds: TimeInterval = 15  // Enable MPC fallback after 15s of ICE checking
    private let h264Encoder = HardwareH264Encoder()
    private var encoderConfigured = false

    // MARK: - UI
    private var preview: RTCMTLVideoView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebRTC()
        setupPreview()
        setupSignaling()
        startCapture()
    }

    // MARK: - Setup

    private func setupWebRTC() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        if let h264 = encoderFactory.supportedCodecs().first(where: { $0.name == kRTCVideoCodecH264Name }) {
            encoderFactory.preferredCodec = h264
        }

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
        config.disableLinkLocalNetworks = false

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        videoSource = factory.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: self)
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")

        if let localVideoTrack {
            print("Sender: Created local video track early")
            print("Sender: Video track ID: \(localVideoTrack.trackId)")
            print("Sender: Video track enabled at creation: \(localVideoTrack.isEnabled)")

            let sender = peerConnection.add(localVideoTrack, streamIds: ["stream0"])
            print("Sender: Added video track to peer connection immediately, sender: \(sender?.track?.kind ?? "nil")")
            print("Sender: RTP sender parameters at add time: \(sender?.parameters ?? RTCRtpParameters())")
        } else {
            print("Sender: Failed to create initial video track")
        }
    }

    private func setupPreview() {
        preview = RTCMTLVideoView(frame: view.bounds)
        preview.videoContentMode = .scaleAspectFill
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.backgroundColor = .blue // Debug color to verify view is there
        view.addSubview(preview)

        print("Sender: setupPreview - preview frame: \(preview.frame)")
        print("Sender: setupPreview - preview ready; video track will attach after capture starts")
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
                debugCandidate("SENDER", direction: "RECEIVED", candidate: candSdp)
                let cand = RTCIceCandidate(
                    sdp: candSdp,
                    sdpMLineIndex: sdpMLineIndex,
                    sdpMid: sdpMid
                )
                if self.peerConnection.remoteDescription != nil {
                    self.peerConnection.add(cand) { error in
                        if let error = error {
                            debugICE("SENDER failed to add candidate: \(error)")
                        }
                    }
                } else {
                    self.pendingCandidates.append(cand)
                    debugICE("SENDER queued candidate (no remote desc yet)")
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

                // For landscape devices, we may need to swap dimensions
                var outputWidth = dimensions.width
                var outputHeight = dimensions.height

                // Check device orientation and adjust if needed
                let deviceOrientation = UIDevice.current.orientation
                let isLandscape = deviceOrientation.isLandscape || UIScreen.main.bounds.width > UIScreen.main.bounds.height

                if UIDevice.current.userInterfaceIdiom == .pad && isLandscape {
                    // For landscape iPads, ensure we're capturing in landscape orientation
                    if dimensions.height > dimensions.width {
                        // Swap dimensions if needed
                        outputWidth = dimensions.height
                        outputHeight = dimensions.width
                        print("Sender: Swapping dimensions for landscape iPad: \(outputWidth)x\(outputHeight)")
                    }
                }

                self.videoSource.adaptOutputFormat(toWidth: outputWidth, height: outputHeight, fps: Int32(fps))
                self.capturer.startCapture(with: device, format: format, fps: fps)
                self.isCapturerRunning = true
                self.lastFrameTime = Date()

                print("Sender: Video source state: \(String(describing: self.videoSource))")

                if let track = self.localVideoTrack {
                    if !self.isPreviewAttached {
                        print("Sender: Attaching existing video track to preview...")
                        track.add(self.preview)
                        self.isPreviewAttached = true
                        print("Sender: Video track attached to preview")
                    }

                    if !track.isEnabled {
                        track.isEnabled = true
                        print("Sender: Video track explicitly enabled: \(track.isEnabled)")
                    }

                    if !self.hasSentInitialOffer {
                        self.hasSentInitialOffer = true
                        print("Sender: Video track live; sending offer with media")
                        self.makeOffer()
                    }
                } else {
                    print("Sender: WARNING - localVideoTrack unavailable when capture started")
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

        videoSource.adaptOutputFormat(toWidth: CMVideoFormatDescriptionGetDimensions(format.formatDescription).width,
                                      height: CMVideoFormatDescriptionGetDimensions(format.formatDescription).height,
                                      fps: Int32(fps))
        capturer.startCapture(with: device, format: format, fps: fps)
        isCapturerRunning = true

        // Reset frame tracking
        lastFrameTime = Date()
        frameCount = 0

        // Re-enable track if it exists
        localVideoTrack?.isEnabled = true
        if let track = localVideoTrack, !isPreviewAttached {
            track.add(preview)
            isPreviewAttached = true
        }

        hasSentInitialOffer = false
        print("Sender: Video capture restarted successfully, renegotiating offer")
        makeOffer()
    }

    // MARK: - WebRTC Statistics and Diagnostics

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
                print("🔍 SENDER WEBRTC STATS (Δ\(String(format: "%.1f", timeDiff))s):")
            }

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

                // Outbound RTP (what we're sending)
                if shouldLogStats,
                   stat.type == "outbound-rtp" && stat.values["mediaType"] as? String == "video" {
                    if let bytes = stat.values["bytesSent"] as? NSNumber {
                        bytesSent = bytes.uint64Value
                        videoSent = bytesSent
                    }
                    if let packets = stat.values["packetsSent"] as? NSNumber {
                        packetsSent = packets.uint32Value
                    }
                    if let lost = stat.values["packetsLost"] as? NSNumber {
                        packetsLost = lost.uint32Value
                    }
                    if let fps = stat.values["framesPerSecond"] as? NSNumber {
                        framesPerSecond = fps.doubleValue
                    }
                    if let width = stat.values["frameWidth"] as? NSNumber {
                        frameWidth = width.uint32Value
                    }
                    if let height = stat.values["frameHeight"] as? NSNumber {
                        frameHeight = height.uint32Value
                    }
                    if let impl = stat.values["encoderImplementation"] as? String {
                        encoderImplementation = impl
                    }
                }

                // Candidate pair (connection quality)
                if shouldLogStats, stat.type == "candidate-pair" && stat.values["state"] as? String == "succeeded" {
                    if let rtt = stat.values["currentRoundTripTime"] as? NSNumber {
                        print("  📡 RTT: \(String(format: "%.0f", rtt.doubleValue * 1000))ms")
                    }
                    if let available = stat.values["availableOutgoingBitrate"] as? NSNumber {
                        print("  📊 Available outgoing: \(String(format: "%.1f", available.doubleValue / 1000000))Mbps")
                    }
                }

                // Media source (frame statistics)
                if stat.type == "media-source" && stat.values["kind"] as? String == "video" {
                    if let fps = stat.values["framesPerSecond"] as? NSNumber {
                        print("  🎥 Source FPS: \(String(format: "%.1f", fps.doubleValue))")
                    }
                    if let width = stat.values["width"] as? NSNumber,
                       let height = stat.values["height"] as? NSNumber {
                        print("  📐 Source resolution: \(width.uint32Value)x\(height.uint32Value)")
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
                debugICEPairs("SENDER ICE: No candidate pairs yet")
                return
            }

            let inProgress = pairs.filter { $0.state == "in-progress" }.count
            let succeeded = pairs.filter { $0.state == "succeeded" }.count
            let failed = pairs.filter { $0.state == "failed" }.count
            let waiting = pairs.filter { $0.state == "waiting" }.count
            let frozen = pairs.filter { $0.state == "frozen" }.count

            debugICEPairs("SENDER ICE: \(pairs.count) pairs - succeeded:\(succeeded) in-progress:\(inProgress) waiting:\(waiting) frozen:\(frozen) failed:\(failed)")

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

    // MARK: - Offer / ICE

    private func makeOffer() {
        let hasVideoSender = peerConnection.senders.contains { $0.track?.kind == kRTCMediaStreamTrackKindVideo }
        if !hasVideoSender {
            print("Sender: Skipping offer until a video sender is configured")
            return
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveVideo":"false"],
            optionalConstraints: ["CandidateNetworkPolicy": "low_cost"]
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
        print("Sender: should negotiate (state=\(peerConnection.signalingState.rawValue))")
        if peerConnection.signalingState == .stable {
            print("Sender: Responding to renegotiation request with fresh offer")
            makeOffer()
        } else {
            print("Sender: Skipping renegotiation because signaling state is not stable")
        }
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
        debugICE("SENDER state → \(stateName)")

        if newState == .checking {
            startICEPairMonitoring()
            // Start timeout timer for MPC fallback
            iceCheckingStartTime = Date()
            scheduleICETimeoutCheck()
        } else if newState == .connected || newState == .completed {
            stopICEPairMonitoring()
            iceCheckingStartTime = nil
            debugICE("SENDER ✅ ICE connected successfully!")
            // Disable MPC video fallback since WebRTC is working
            if useMPCVideo {
                useMPCVideo = false
                print("Sender: WebRTC connected, disabling MPC video fallback")
            }
        } else if newState == .failed {
            stopICEPairMonitoring()
            iceCheckingStartTime = nil
            debugICE("SENDER ❌ ICE CONNECTION FAILED - enabling MPC video fallback")
            // Enable MPC video streaming as fallback
            enableMPCVideoFallback()
        } else if newState == .disconnected {
            debugICE("SENDER ⚠️ ICE disconnected")
        }
    }

    private func scheduleICETimeoutCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + iceTimeoutSeconds) { [weak self] in
            self?.checkICETimeout()
        }
    }

    private func checkICETimeout() {
        guard let startTime = iceCheckingStartTime else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= iceTimeoutSeconds {
            // ICE has been checking for too long without success
            let iceState = peerConnection?.iceConnectionState ?? .new
            if iceState == .checking || iceState == .new {
                debugICE("SENDER ⏰ ICE timeout after \(Int(elapsed))s - enabling MPC video fallback")
                enableMPCVideoFallback()
            }
        }
    }

    private func enableMPCVideoFallback() {
        guard !useMPCVideo else { return }
        useMPCVideo = true
        mpcFrameCount = 0
        print("Sender: 📹 MPC video fallback ENABLED - streaming via MultipeerConnectivity")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Sender: ICE gathering → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        debugCandidate("SENDER", direction: "GENERATED", candidate: candidate.sdp)
        signaler.send(SignalMessage.candidate(candidate))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // MARK: - RTCVideoCapturerDelegate

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        frameCount += 1
        lastFrameTime = Date()

        // Forward to video source (for local preview and WebRTC if connected)
        videoSource.capturer(capturer, didCapture: frame)

        // If MPC video fallback is enabled, also send via MPC
        if useMPCVideo {
            sendFrameViaMPC(frame)
        }
    }

    // MARK: - MPC Video Streaming (Hardware H.264)

    private func sendFrameViaMPC(_ frame: RTCVideoFrame) {
        // Rate limit to target FPS
        let now = CACurrentMediaTime()
        let minInterval = 1.0 / mpcTargetFPS
        guard now - lastMPCFrameTime >= minInterval else { return }
        lastMPCFrameTime = now

        // Only send if MPC is connected
        guard signaler.isConnected else { return }

        guard let pixelBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }

        // Configure encoder on first frame
        if !encoderConfigured {
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            h264Encoder.configure(width: width, height: height)
            encoderConfigured = true
        }

        // Get rotation from frame (0=0°, 1=90°, 2=180°, 3=270°)
        let rotation: Int
        switch frame.rotation {
        case ._0: rotation = 0
        case ._90: rotation = 1
        case ._180: rotation = 2
        case ._270: rotation = 3
        @unknown default: rotation = 0
        }

        // Encode using hardware H.264
        let timestamp = CMTime(value: Int64(mpcFrameCount), timescale: 30)
        if let (nalData, isKeyframe) = h264Encoder.encodeSync(pixelBuffer: pixelBuffer, timestamp: timestamp) {
            // Send via MPC with rotation metadata
            signaler.sendVideoFrame(nalData, rotation: rotation)

            mpcFrameCount += 1
            if mpcFrameCount % 60 == 0 {
                let kf = isKeyframe ? " [KF]" : ""
                print("Sender: 📹 H.264 frame \(mpcFrameCount), \(nalData.count / 1024)KB\(kf), rot:\(rotation * 90)°")
            }
        }
    }

}
