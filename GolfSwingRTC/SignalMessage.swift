import Foundation
import WebRTC

enum SignalType: String, Codable {
    case offer, answer, candidate
}

enum SignalMessage: Codable {
    case offer(String)
    case answer(String)
    case candidate(String, sdpMid: String?, sdpMLineIndex: Int32)

    var type: SignalType {
        switch self {
        case .offer: return .offer
        case .answer: return .answer
        case .candidate: return .candidate
        }
    }

    var sdp: String? {
        switch self {
        case .offer(let sdp), .answer(let sdp): return sdp
        case .candidate: return nil
        }
    }

    static func offer(_ sdp: RTCSessionDescription) -> SignalMessage {
        return .offer(sdp.sdp)
    }

    static func answer(_ sdp: RTCSessionDescription) -> SignalMessage {
        return .answer(sdp.sdp)
    }

    static func candidate(_ c: RTCIceCandidate) -> SignalMessage {
        return .candidate(c.sdp, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, sdp, candidate, sdpMid, sdpMLineIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SignalType.self, forKey: .type)

        switch type {
        case .offer:
            let sdp = try container.decode(String.self, forKey: .sdp)
            self = .offer(sdp)
        case .answer:
            let sdp = try container.decode(String.self, forKey: .sdp)
            self = .answer(sdp)
        case .candidate:
            let candidate = try container.decode(String.self, forKey: .candidate)
            let sdpMid = try container.decodeIfPresent(String.self, forKey: .sdpMid)
            let sdpMLineIndex = try container.decode(Int32.self, forKey: .sdpMLineIndex)
            self = .candidate(candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        switch self {
        case .offer(let sdp):
            try container.encode(sdp, forKey: .sdp)
        case .answer(let sdp):
            try container.encode(sdp, forKey: .sdp)
        case .candidate(let candidate, let sdpMid, let sdpMLineIndex):
            try container.encode(candidate, forKey: .candidate)
            try container.encodeIfPresent(sdpMid, forKey: .sdpMid)
            try container.encode(sdpMLineIndex, forKey: .sdpMLineIndex)
        }
    }
}

extension RTCSessionDescription {
    static func from(type: RTCSdpType, sdp: String) -> RTCSessionDescription {
        return RTCSessionDescription(type: type, sdp: sdp)
    }
}
