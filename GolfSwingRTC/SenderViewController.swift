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
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        videoSource = factory.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        _ = peerConnection.add(localVideoTrack, streamIds: ["stream0"])
    }

    private func setupPreview() {
        preview = RTCMTLVideoView(frame: view.bounds)
        preview.videoContentMode = .scaleAspectFill
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(preview)
        localVideoTrack.add(preview)
    }

    private func setupSignaling() {
        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }

            switch msg.type {

            case .answer:
                guard let sdpText = msg.sdp else { return }
                let answer = RTCSessionDescription(type: .answer, sdp: sdpText)
                self.peerConnection.setRemoteDescription(answer) { error in
                    if let error = error {
                        print("Sender: failed to set remote answer: \(error)")
                        return
                    }
                    self.applyPendingCandidates()
                }

            case .candidate:
                guard let candSdp = msg.candidate else { return }
                let cand = RTCIceCandidate(
                    sdp: candSdp,
                    sdpMLineIndex: msg.sdpMLineIndex ?? 0,
                    sdpMid: msg.sdpMid
                )
                if self.peerConnection.remoteDescription != nil {
                    self.peerConnection.add(cand)
                    print("Sender: applied candidate")
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
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { return }
                guard let device = RTCCameraVideoCapturer.captureDevices()
                        .first(where: { $0.position == .back }) ?? RTCCameraVideoCapturer.captureDevices().first
                else { return }

                let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
                // choose the highest resolution format
                let format = formats.max(by: {
                    let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                    return (a.width * a.height) < (b.width * b.height)
                }) ?? formats.first!

                let maxFps = Int(format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30)
                let fps = max(24, min(60, maxFps))

                self.capturer.startCapture(with: device, format: format, fps: fps)
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
            self.signaler.send(SignalMessage.offer(sdp))
            print("Sender: sent offer")
        }
    }

    private func applyPendingCandidates() {
        for c in pendingCandidates { peerConnection.add(c) }
        pendingCandidates.removeAll()
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
        print("Sender: ICE state → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Sender: ICE gathering → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Sender: generated candidate")
        signaler.send(SignalMessage.candidate(candidate))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
