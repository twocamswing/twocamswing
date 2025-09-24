import UIKit
import WebRTC
import AVFoundation

final class ReceiverViewController: UIViewController {
    var pc:RTCPeerConnection!
    private var factory: RTCPeerConnectionFactory!
    private var peerConnection: RTCPeerConnection!
    private var playerView: RTCMTLVideoView!
    private let signaler = MPCSignaler()
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
        setupUI()
        setupSignaling()
    }

    private func setupWebRTC() {
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)

        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":"true"])
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        // Receive-only transceiver for video (Unified Plan)
        let _ = peerConnection.addTransceiver(of: .video)
    }

    private func setupUI() {
        playerView = RTCMTLVideoView(frame: view.bounds)
        playerView.videoContentMode = .scaleAspectFit
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerView)
    }

    private func setupSignaling() {
        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }
            switch msg {
            case .offer(let sdp):
                let offer = RTCSessionDescription(type: .offer, sdp: sdp)
                self.pc.setRemoteDescription(offer) { error in
                    if let error = error {
                        print("Receiver: failed to set remote offer: \(error)")
                        return
                    }
                    // 👇 after remote offer is set, apply any buffered candidates
                    self.applyPendingCandidates()

                    // Now create & send answer
                    self.pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                        if let answer = answer {
                            self.pc.setLocalDescription(answer, completionHandler: nil)
                            self.signaler.send(.answer(answer))
                        }
                    }
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
}

extension ReceiverViewController: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Receiver: signaling state changed → \(stateChanged.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Receiver: remote stream added")
        DispatchQueue.main.async {
            if let track = stream.videoTracks.first {
                print("Receiver: attaching remote video track")
                track.add(self.playerView)
            }
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {
        print("Receiver: should negotiate")
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("Receiver: ICE connection state → \(newState.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Receiver: ICE gathering state → \(newState.rawValue)")
    }

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            if pc.remoteDescription != nil {
                signaler.send(.candidate(candidate))
            } else {
                pendingCandidates.append(candidate)
            }
        }

    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}


