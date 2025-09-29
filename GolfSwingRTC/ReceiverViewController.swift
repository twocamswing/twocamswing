import UIKit
import WebRTC
import MultipeerConnectivity
import Foundation

class DebugVideoRenderer: NSObject, RTCVideoRenderer {
    func setSize(_ size: CGSize) {
        print("DebugRenderer: setSize called with \(size)")
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        print("DebugRenderer: renderFrame called with frame size: \(frame?.width ?? 0)x\(frame?.height ?? 0)")
    }
}

final class ReceiverViewController: UIViewController, RTCPeerConnectionDelegate {
    private var remoteVideoView: RTCMTLVideoView!
    private var peerConnection: RTCPeerConnection!
    private let factory = RTCPeerConnectionFactory()
    private let signaler = MPCSignaler(role: .browser)   // use .browser role
    private let debugRenderer = DebugVideoRenderer()

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
        remoteVideoView.backgroundColor = .red // Temporary debug color
        view.addSubview(remoteVideoView)

        print("Receiver: setupVideoView completed - frame: \(remoteVideoView.frame)")
        print("Receiver: Video view added to superview: \(remoteVideoView.superview != nil)")
        print("Receiver: Device screen bounds: \(UIScreen.main.bounds)")
        print("Receiver: Device scale: \(UIScreen.main.scale)")
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
            print("Receiver: Video track found, attaching to view...")
            let workItem = DispatchWorkItem {
                print("Receiver: On main queue, video view frame: \(self.remoteVideoView.frame)")
                print("Receiver: Video view superview: \(self.remoteVideoView.superview != nil)")
                print("Receiver: Track is enabled: \(track.isEnabled)")

                track.add(self.remoteVideoView)
                track.add(self.debugRenderer)
                print("Receiver: Video track attached successfully")
                print("Receiver: Debug renderer also attached")
                print("Receiver: Video track state: enabled=\(track.isEnabled) readyState=\(track.readyState.rawValue)")

                // Test if the debug renderer is actually called
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    print("Receiver: Testing if debug renderer gets called - checking track stats...")
                    print("Receiver: Track enabled after 3s: \(track.isEnabled)")
                    print("Receiver: Track ready state after 3s: \(track.readyState.rawValue)")

                    // Try to manually trigger a debug call
                    self.debugRenderer.setSize(CGSize(width: 100, height: 100))
                    print("Receiver: Manual debug renderer setSize called")
                }

                // Force a layout update after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print("Receiver: Forcing video view layout update...")
                    self.remoteVideoView.setNeedsDisplay()
                    self.view.setNeedsLayout()
                }

                // Force video view to front and refresh
                self.remoteVideoView.setNeedsLayout()
                self.remoteVideoView.layoutIfNeeded()
                self.view.bringSubviewToFront(self.remoteVideoView)

                print("Receiver: Video view brought to front and refreshed")
            }
            DispatchQueue.main.async(execute: workItem)
        } else {
            print("Receiver: No video track found in rtpReceiver")
        }
    }
}
