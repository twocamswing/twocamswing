import Foundation
import MultipeerConnectivity

enum Role { case advertiser, browser }

// Magic bytes to distinguish video frames from signaling messages
private let videoFrameMagic: [UInt8] = [0x56, 0x46, 0x52, 0x4D] // "VFRM"

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
    var onVideoFrame: ((Data, Int) -> Void)?  // Callback for received video frames: (h264Data, rotation)

    init(role: Role) {
        super.init()
        print("MPC: Initializing MPCSignaler as \(role) with peer ID: \(peerID.displayName)")

        switch role {
        case .advertiser:
            print("MPC: Starting as ADVERTISER for service type: \(serviceType)")
            let adv = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
            adv.delegate = self
            adv.startAdvertisingPeer()
            advertiser = adv
            print("MPC: Advertiser started, waiting for browsers...")
        case .browser:
            print("MPC: Starting as BROWSER for service type: \(serviceType)")
            let b = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
            print("MPC: Browser started, searching for advertisers...")
        }
    }

    func send(_ message: SignalMessage) {
        guard let data = try? JSONEncoder().encode(message) else {
            print("MPC send: failed to encode \(message.type)")
            return
        }
        let json = String(data: data, encoding: .utf8) ?? ""

        if session.connectedPeers.isEmpty {
            print("MPC → QUEUED (no peers): \(json.prefix(200))...")
            outbox.append(data)
            print("MPC: Outbox size now: \(outbox.count)")
            return
        }

        print("MPC → SEND to \(session.connectedPeers.count) peers: \(json.prefix(200))...")
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("MPC: Message sent successfully to peers: \(session.connectedPeers.map { $0.displayName })")
        } catch {
            print("MPC: Failed to send message: \(error)")
        }
    }

    private func flushOutboxIfNeeded() {
        guard !session.connectedPeers.isEmpty, !outbox.isEmpty else {
            if session.connectedPeers.isEmpty {
                print("MPC: Cannot flush outbox - no connected peers")
            } else {
                print("MPC: Outbox is empty, nothing to flush")
            }
            return
        }

        let peers = session.connectedPeers
        print("MPC: Flushing \(outbox.count) queued messages to \(peers.count) peers...")

        var successCount = 0
        for (index, data) in outbox.enumerated() {
            do {
                try session.send(data, toPeers: peers, with: .reliable)
                successCount += 1
            } catch {
                print("MPC: Failed to flush message \(index): \(error)")
            }
        }

        print("MPC: Successfully flushed \(successCount)/\(outbox.count) messages")
        outbox.removeAll()
    }

    // MARK: - Video Frame Streaming

    /// Send a video frame (H.264 data) with rotation metadata to connected peers
    /// Format: [4 bytes magic] [1 byte rotation: 0=0°, 1=90°, 2=180°, 3=270°] [H.264 NAL data]
    func sendVideoFrame(_ h264Data: Data, rotation: Int = 0) {
        guard !session.connectedPeers.isEmpty else { return }

        // Prepend magic bytes and rotation to distinguish from signaling messages
        var frameData = Data(videoFrameMagic)
        frameData.append(UInt8(rotation & 0x03))  // 2 bits for rotation (0-3)
        frameData.append(h264Data)

        do {
            // Use unreliable mode for lower latency - dropped frames are acceptable
            try session.send(frameData, toPeers: session.connectedPeers, with: .unreliable)
        } catch {
            // Don't log every frame error to avoid spam
        }
    }

    /// Check if MPC is connected to peers
    var isConnected: Bool {
        return !session.connectedPeers.isEmpty
    }
}

extension MPCSignaler: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name: String
        switch state {
        case .notConnected: name = "not connected"
        case .connecting: name = "connecting"
        case .connected: name = "connected"
        @unknown default: name = "unknown(\(state.rawValue))"
        }
        print("MPC: \(peerID.displayName) → \(name) (rawValue: \(state.rawValue))")
        print("MPC: Session connected peers count: \(session.connectedPeers.count)")
        print("MPC: All connected peers: \(session.connectedPeers.map { $0.displayName })")

        if state == .connected {
            print("MPC: Peer \(peerID.displayName) connected, flushing outbox...")
            flushOutboxIfNeeded()
            onConnected?()
        } else if state == .notConnected {
            print("MPC: Peer \(peerID.displayName) disconnected! Reason unknown.")
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Check if this is a video frame (starts with magic bytes)
        // Format: [4 bytes magic] [1 byte rotation] [H.264 data]
        if data.count > 5 {
            let prefix = [UInt8](data.prefix(4))
            if prefix == videoFrameMagic {
                // Extract rotation byte and H.264 data after magic bytes
                let rotation = Int(data[4])
                let h264Data = data.dropFirst(5)
                DispatchQueue.main.async {
                    self.onVideoFrame?(Data(h264Data), rotation)
                }
                return
            }
        }

        // Otherwise, treat as signaling message
        print("MPC: Received \(data.count) bytes from \(peerID.displayName)")

        guard let msg = try? JSONDecoder().decode(SignalMessage.self, from: data) else {
            print("MPC: ERROR - Failed to decode message from \(peerID.displayName)")
            return
        }

        let logMsg = switch msg {
        case .offer(let sdp):
            "offer | sdp: \(sdp.prefix(50))..."
        case .answer(let sdp):
            "answer | sdp: \(sdp.prefix(50))..."
        case .candidate(let cand, _, _):
            "candidate | cand: \(cand.prefix(50))..."
        }
        print("MPC ← received: \(logMsg) | from: \(peerID.displayName)")

        DispatchQueue.main.async {
            print("MPC: Dispatching \(msg.type) message to main queue")
            self.onMessage?(msg)
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
