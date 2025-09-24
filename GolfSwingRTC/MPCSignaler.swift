import Foundation
import MultipeerConnectivity

enum Role { case advertiser, browser }

final class MPCSignaler: NSObject {
    private let serviceType = "webrtc-signal"
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session: MCSession = {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()

    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // Outbox buffers messages until MPC is connected
    private var outbox: [Data] = []

    // Callbacks
    var onMessage: ((SignalMessage) -> Void)?
    var onConnected: (() -> Void)?

    init(role: Role) {
        super.init()
        switch role {
        case .advertiser:
            let adv = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
            adv.delegate = self
            adv.startAdvertisingPeer()
            advertiser = adv
        case .browser:
            let b = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
        }
    }

    func send(_ message: SignalMessage) {
        guard let data = try? JSONEncoder().encode(message) else {
            print("MPC send: failed to encode \(message.type)")
            return
        }
        let json = String(data: data, encoding: .utf8) ?? ""
        print("MPC → enqueue/send: \(json)")

        if session.connectedPeers.isEmpty {
            // buffer until connected
            outbox.append(data)
            return
        }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    private func flushOutboxIfNeeded() {
        guard !session.connectedPeers.isEmpty, !outbox.isEmpty else { return }
        let peers = session.connectedPeers
        for data in outbox {
            try? session.send(data, toPeers: peers, with: .reliable)
        }
        outbox.removeAll()
    }
}

extension MPCSignaler: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name: String
        switch state { case .notConnected: name = "not connected"; case .connecting: name = "connecting"; case .connected: name = "connected"; @unknown default: name = "unknown" }
        print("MPC: \(peerID.displayName) → \(name)")
        if state == .connected {
            flushOutboxIfNeeded()
            onConnected?()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let msg = try? JSONDecoder().decode(SignalMessage.self, from: data) {
            print("MPC ← received: \(msg.type) | from: \(peerID.displayName) | sdp:\(msg.sdp ?? "nil") | cand:\(msg.candidate ?? "nil")")
            DispatchQueue.main.async { self.onMessage?(msg) }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MPCSignaler: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("MPC: received invite from \(peerID.displayName)")
        invitationHandler(true, session)
    }
}

extension MPCSignaler: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("MPC: found peer \(peerID.displayName)")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
