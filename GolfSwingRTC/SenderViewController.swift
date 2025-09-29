import UIKit
import AVFoundation
import WebRTC

final class SenderViewController: UIViewController, RTCPeerConnectionDelegate {

    // MARK: - WebRTC
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection!
    private var videoSource: RTCVideoSource!
    private var capturer: RTCCameraVideoCapturer!
    private var localVideoTrack: RTCVideoTrack!

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
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")

        // Note: capturer already has videoSource as delegate for rendering
        // We'll get frame info through the RTCVideoCapturerDelegate protocol

        // Add video track to peer connection
        let sender = peerConnection.add(localVideoTrack, streamIds: ["stream0"])
        print("Sender: Added video track to peer connection, sender: \(sender?.track?.kind ?? "nil")")
        print("Sender: RTP sender parameters: \(sender?.parameters ?? RTCRtpParameters())")
        print("Sender: Video track ID: \(localVideoTrack.trackId)")
        print("Sender: Video track enabled at add: \(localVideoTrack.isEnabled)")
        print("Sender: Video track ready state at add: \(localVideoTrack.readyState.rawValue)")
    }

    private func setupPreview() {
        preview = RTCMTLVideoView(frame: view.bounds)
        preview.videoContentMode = .scaleAspectFill
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.backgroundColor = .blue // Debug color to verify view is there
        view.addSubview(preview)

        print("Sender: setupPreview - preview frame: \(preview.frame)")
        print("Sender: setupPreview - localVideoTrack state before add: enabled=\(localVideoTrack.isEnabled) readyState=\(localVideoTrack.readyState.rawValue)")

        // Don't attach video track here - wait for capture to start
        print("Sender: setupPreview - preview created, video track attachment deferred until capture starts")
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

                print("Sender: Video track enabled: \(self.localVideoTrack.isEnabled)")
                print("Sender: Video source state: \(String(describing: self.videoSource))")

                // Attach to preview immediately after capture starts
                print("Sender: Attaching video track to preview after capture start...")
                self.localVideoTrack.add(self.preview)
                print("Sender: Video track attached to preview")

                // Verify video pipeline after capture starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("Sender: Verifying video pipeline after 2 seconds...")
                    print("Sender: Video track enabled: \(self.localVideoTrack.isEnabled)")
                    print("Sender: Video track ready state: \(self.localVideoTrack.readyState.rawValue)")
                    print("Sender: Video source state: \(String(describing: self.videoSource))")
                    print("Sender: Preview frame: \(self.preview.frame)")
                    print("Sender: Preview superview: \(self.preview.superview != nil)")

                    // Force preview to refresh
                    self.preview.setNeedsLayout()
                    self.preview.layoutIfNeeded()
                    self.view.bringSubviewToFront(self.preview)
                    print("Sender: Preview refreshed and brought to front")

                    // Check if we should enable the track manually
                    if self.localVideoTrack.readyState.rawValue == 0 {
                        print("Sender: Video track ready state is still 0, this may indicate a pipeline issue")
                    }
                }
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

}
