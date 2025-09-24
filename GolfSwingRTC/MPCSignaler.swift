import Foundation
import MultipeerConnectivity

final class MPCSignaler: NSObject {
    private let serviceType = "webrtc-signal"
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session: MCSession = {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    private lazy var advertiser: MCNearbyServiceAdvertiser = {
        let adv = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        adv.delegate = self
        return adv
    }()
    private lazy var browser: MCNearbyServiceBrowser = {
        let b = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        b.delegate = self
        return b
    }()

    var onMessage: ((SignalMessage) -> Void)?

    override init() {
        super.init()
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func send(_ message: SignalMessage) {
        if let data = try? JSONEncoder().encode(message) {
            print("MPC → sending: \(message.type)")
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }
}

extension MPCSignaler: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let stateName: String
        switch state {
        case .notConnected: stateName = "not connected"
        case .connecting: stateName = "connecting"
        case .connected: stateName = "connected"
        @unknown default: stateName = "unknown"
        }
        print("MPC: \(peerID.displayName) → \(stateName)")
    }


    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let msg = try? JSONDecoder().decode(SignalMessage.self, from: data) {
            print("MPC ← received: \(msg.type)")
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

