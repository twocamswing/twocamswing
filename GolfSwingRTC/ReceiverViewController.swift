import UIKit
import WebRTC

final class ReceiverViewController: UIViewController {
    private var factory: RTCPeerConnectionFactory!
    private var pc: RTCPeerConnection!
    private var remoteView: RTCMTLVideoView!
    private let signaler = MPCSignaler(role: .browser)

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

        // Explicitly expect video
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: transceiverInit)

        // Remote video view
        remoteView = RTCMTLVideoView(frame: view.bounds)
        remoteView.videoContentMode = .scaleAspectFit
        remoteView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(remoteView)
    }

    private func setupSignaling() {
        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }
            switch msg.type {
            case .offer:
                print("Receiver: got offer")
                guard let sdpString = msg.sdp else { return }
                let offer = RTCSessionDescription(type: .offer, sdp: sdpString)
                self.pc.setRemoteDescription(offer) { err in
                    print("Receiver: setRemoteDescription(offer) \(err?.localizedDescription ?? "ok")")
                    guard err == nil else { return }

                    self.applyPendingCandidates()
                    self.pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil,
                                                            optionalConstraints: nil)) { answer, aerr in
                        guard let answer = answer, aerr == nil else {
                            print("Receiver: failed to create answer \(String(describing: aerr))")
                            return
                        }
                        self.pc.setLocalDescription(answer) { serr in
                            print("Receiver: setLocalDescription(answer) \(serr?.localizedDescription ?? "ok")")
                        }
                        print("Receiver: sending answer")
                        self.signaler.send(SignalMessage.answer(answer))
                    }
                }

            case .candidate:
                print("Receiver: got candidate")
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
}

extension ReceiverViewController: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { print("Receiver: signaling → \(stateChanged.rawValue)") }

    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Receiver: didAdd stream (fallback)")
        if let track = stream.videoTracks.first {
            track.add(remoteView)
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        print("Receiver: didAdd rtpReceiver")
        if let track = rtpReceiver.track as? RTCVideoTrack {
            print("Receiver: attaching video track")
            track.add(remoteView)
        }
    }

    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) { print("Receiver: should negotiate") }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) { print("Receiver: ICE state → \(newState.rawValue)") }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) { print("Receiver: ICE gathering → \(newState.rawValue)") }
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Receiver: generated candidate")
        signaler.send(SignalMessage.candidate(candidate))
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
