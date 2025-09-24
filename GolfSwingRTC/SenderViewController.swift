import UIKit
import WebRTC
import AVFoundation

final class SenderViewController: UIViewController {
    var pc: RTCPeerConnection!
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection!
    private var videoSource: RTCVideoSource!
    private var capturer: RTCCameraVideoCapturer!
    private var localVideoTrack: RTCVideoTrack!
    private let signaler = MPCSignaler()
    private var preview: RTCMTLVideoView!
    
    var pendingCandidates: [RTCIceCandidate] = []

        func applyPendingCandidates() {
            for c in pendingCandidates {
                pc.add(c)
            }
            pendingCandidates.removeAll()
        }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebRTC()
        setupSignaling()
        startCapture()
        makeOffer()
    }

    private func setupWebRTC() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)

        let config = RTCConfiguration()
        config.iceServers = [] // local only
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":"true"])
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        videoSource = factory.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        _ = peerConnection.add(localVideoTrack, streamIds: ["stream0"])

        preview = RTCMTLVideoView(frame: view.bounds)
        preview.videoContentMode = .scaleAspectFill
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(preview)
        localVideoTrack.add(preview)
    }

    private func setupSignaling() {
        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }
            switch msg {
            case .answer(let sdp):
                let answer = RTCSessionDescription(type: .answer, sdp: sdp)
                self.pc.setRemoteDescription(answer) { error in
                    if let error = error {
                        print("Sender: failed to set remote answer: \(error)")
                        return
                    }
                    // 👇 after remote answer is set, apply any buffered candidates
                    self.applyPendingCandidates()
                }

            case .candidate(let c):
                let candidate = RTCIceCandidate(sdp: c.sdp, sdpMLineIndex: c.sdpMLineIndex, sdpMid: c.sdpMid)
                if self.pc.remoteDescription != nil {
                    self.pc.add(candidate)
                } else {
                    self.pendingCandidates.append(candidate)   // 👈 buffer
                }

            default: break
            }
        }
    }

    private func startCapture() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { return }
                guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .back }) ?? RTCCameraVideoCapturer.captureDevices().first else { return }
                let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
                let format = formats.sorted { f1, f2 in
                    CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width < CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
                }.last ?? formats.first!

                let fps = Int((format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30).clamped(to: 24...60))
                self.capturer.startCapture(with: device, format: format, fps: fps)
            }
        }
    }

    private func makeOffer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveVideo":"false"],
                                              optionalConstraints: nil)
        peerConnection.offer(for: constraints) { [weak self] sdp, err in
            guard let self = self, let sdp = sdp, err == nil else {
                print("offer error: \(String(describing: err))")
                return
            }
            self.peerConnection.setLocalDescription(sdp) { err in
                if let err = err { print("setLocalDescription(offer) error: \(err)") }
            }
            self.signaler.send(.offer(sdp))
        }
    }
}

extension SenderViewController: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Sender: signaling state changed → \(stateChanged.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Sender: remote stream added (unexpected for sender)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {
        print("Sender: should negotiate")
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("Sender: ICE connection state → \(newState.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Sender: ICE gathering state → \(newState.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Sender: generated ICE candidate")
        signaler.send(.candidate(candidate))
    }

    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}


fileprivate extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

