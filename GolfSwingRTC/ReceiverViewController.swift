import UIKit
import WebRTC

final class ReceiverViewController: UIViewController, RTCPeerConnectionDelegate {
    private var remoteVideoView: RTCMTLVideoView!
    private var peerConnection: RTCPeerConnection!
    private let factory = RTCPeerConnectionFactory()
    private let signaler = MPCSignaler(role: .browser)   // use .browser role

    override func viewDidLoad() {
        super.viewDidLoad()
        setupVideoView()
        setupPeerConnection()
        setupSignaler()
    }

    private func setupVideoView() {
        remoteVideoView = RTCMTLVideoView(frame: view.bounds)
        remoteVideoView.videoContentMode = .scaleAspectFit
        remoteVideoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(remoteVideoView)
    }

    private func setupPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    private func setupSignaler() {
        signaler.onMessage = { [weak self] msg in
            guard let self = self else { return }
            switch msg {
            case .offer(let sdpText):
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
                        print("Receiver: sending answer")
                        self.signaler.send(.answer(sdp.sdp))
                    }
                }

            case .candidate(let sdp, let sdpMid, let sdpMLineIndex):
                let candidate = RTCIceCandidate(
                    sdp: sdp,
                    sdpMLineIndex: sdpMLineIndex,
                    sdpMid: sdpMid
                )
                self.peerConnection.add(candidate)
            default:
                break
            }
        }
    }

    // MARK: - RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Receiver: signaling → \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Receiver: didAdd stream")
        if let track = stream.videoTracks.first {
            track.add(remoteVideoView)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("Receiver: didRemove stream")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("Receiver: should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("Receiver: ICE state → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("Receiver: ICE gathering → \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Receiver: generated candidate")
        signaler.send(.candidate(
            candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        ))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("Receiver: removed candidates")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("Receiver: data channel opened")
    }
}
