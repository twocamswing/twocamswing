import UIKit
import WebRTC
import AVFoundation

final class SenderViewController: UIViewController {
    private var factory: RTCPeerConnectionFactory!
    private var pc: RTCPeerConnection!
    private var videoSource: RTCVideoSource!
    private var capturer: RTCCameraVideoCapturer!
    private var localVideoTrack: RTCVideoTrack!
    private let signaler = MPCSignaler(role: .advertiser)
    private var preview: RTCMTLVideoView!

    private var pendingCandidates: [RTCIceCandidate] = []
    private func applyPendingCandidates() {
        for c in pendingCandidates { pc.add(c) }
        pendingCandidates.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebRTC()
        setupSignaling()
        startCapture()
        // Offer will be created automatically when MPC connects
    }

    private func setupWebRTC() {
        let enc = RTCDefaultVideoEncoderFactory()
        let dec = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)

        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":"true"])
        pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        // Local video track
        videoSource = factory.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")

        // Add as transceiver BEFORE offer
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        pc.addTransceiver(with: localVideoTrack, init: transceiverInit)

        // Local preview
        preview = RTCMTLVideoView(frame: view.bounds)
        preview.videoContentMode = .scaleAspectFill
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(preview)
        localVideoTrack.add(preview)
    }

    private func setupSignaling() {
        // Start offer only after MPC is connected
        signaler.onConnected = { [weak self] in
            print("Sender: MPC connected → creating offer")
            self?.makeOffer()
        }

        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }
            switch msg.type {
            case .answer:
                print("Sender: got answer")
                guard let sdpString = msg.sdp else { return }
                let answer = RTCSessionDescription(type: .answer, sdp: sdpString)
                self.pc.setRemoteDescription(answer) { err in
                    print("Sender: setRemoteDescription(answer) \(err?.localizedDescription ?? "ok")")
                    self.applyPendingCandidates()
                }
            case .candidate:
                print("Sender: got candidate")
                guard let cand = msg.candidate else { return }
                let c = RTCIceCandidate(sdp: cand,
                                        sdpMLineIndex: msg.sdpMLineIndex ?? 0,
                                        sdpMid: msg.sdpMid)
                if self.pc.remoteDescription != nil { self.pc.add(c) }
                else { self.pendingCandidates.append(c) }
            default: break
            }
        }
    }

    private func startCapture() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { return }
                let device = RTCCameraVideoCapturer.captureDevices()
                    .first(where: { $0.position == .back }) ?? RTCCameraVideoCapturer.captureDevices().first!
                let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
                let format = formats.sorted {
                    CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                    CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
                }.last ?? formats.first!
                let fps = Int((format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30).clamped(to: 24...60))
                self.capturer.startCapture(with: device, format: format, fps: fps)
            }
        }
    }

    private func makeOffer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveVideo":"false"], optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, err in
            guard let self = self, let sdp = sdp, err == nil else {
                print("Sender: offer error \(String(describing: err))")
                return
            }
            self.pc.setLocalDescription(sdp) { err in
                print("Sender: setLocalDescription(offer) \(err?.localizedDescription ?? "ok")")
            }
            print("Sender: sending offer")
            self.signaler.send(SignalMessage.offer(sdp))
        }
    }
}

extension SenderViewController: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { print("Sender: signaling → \(stateChanged.rawValue)") }
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) { print("Sender: should negotiate") }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) { print("Sender: ICE state → \(newState.rawValue)") }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) { print("Sender: ICE gathering → \(newState.rawValue)") }
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Sender: generated candidate")
        signaler.send(SignalMessage.candidate(candidate))
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

fileprivate extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

