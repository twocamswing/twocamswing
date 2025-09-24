import Foundation
import WebRTC

enum SignalType: String, Codable {
    case offer, answer, candidate
}

struct SignalMessage: Codable {
    let type: SignalType
    let sdp: String?
    let candidate: String?
    let sdpMid: String?
    let sdpMLineIndex: Int32?

    static func offer(_ sdp: RTCSessionDescription) -> SignalMessage {
        return SignalMessage(type: .offer, sdp: sdp.sdp, candidate: nil, sdpMid: nil, sdpMLineIndex: nil)
    }
    static func answer(_ sdp: RTCSessionDescription) -> SignalMessage {
        return SignalMessage(type: .answer, sdp: sdp.sdp, candidate: nil, sdpMid: nil, sdpMLineIndex: nil)
    }
    static func candidate(_ c: RTCIceCandidate) -> SignalMessage {
        return SignalMessage(type: .candidate, sdp: nil, candidate: c.sdp, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex)
    }
}

extension RTCSessionDescription {
    static func from(type: RTCSdpType, sdp: String) -> RTCSessionDescription {
        return RTCSessionDescription(type: type, sdp: sdp)
    }
}
