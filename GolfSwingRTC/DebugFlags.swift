import Foundation
import os.log

private let iceLog = OSLog(subsystem: "com.golfswingrtc", category: "ICE")

struct DebugFlags {
    // === CURRENT INVESTIGATION: Offline ICE connectivity ===
    // Enable these to debug why WebRTC fails without infrastructure Wi-Fi
    static let iceCandidates = true       // Log every ICE candidate generated/received (IP, type, interface)
    static let iceConnectionFlow = true   // Log ICE state transitions and candidate pair selection
    static let icePairChecks = true       // Log ICE candidate pair connectivity check results

    // Video rendering debugging
    static let videoRendering = false
    static let videoFrameTracking = false  // Turn off noisy frame logs

    // WebRTC stats debugging
    static let webrtcStats = false
    static let webrtcDetailed = false

    // Network/MPC debugging
    static let networkLogging = false
    static let mpcDetailed = false

    // ICE connection debugging (detailed stats - verbose)
    static let iceDetailed = false

    // Critical issues only
    static let criticalOnly = true
}

// Convenience logging functions
func debugVideo(_ message: String) {
    if DebugFlags.videoRendering {
        print("🎥 VIDEO: \(message)")
    }
}

func debugFrame(_ message: String) {
    if DebugFlags.videoFrameTracking {
        print("🖼️ FRAME: \(message)")
    }
}

func debugWebRTC(_ message: String) {
    if DebugFlags.webrtcStats {
        print("📊 WEBRTC: \(message)")
    }
}

func debugCritical(_ message: String) {
    if DebugFlags.criticalOnly {
        print("🚨 CRITICAL: \(message)")
    }
}

func debugNetwork(_ message: String) {
    if DebugFlags.networkLogging {
        print("📡 NETWORK: \(message)")
    }
}

func debugICE(_ message: String) {
    if DebugFlags.iceConnectionFlow {
        let msg = "🧊 ICE: \(message)"
        print(msg)
        os_log("%{public}@", log: iceLog, type: .info, msg)
    }
}

func debugICEPairs(_ message: String) {
    if DebugFlags.icePairChecks {
        let msg = "🔗 \(message)"
        print(msg)
        os_log("%{public}@", log: iceLog, type: .info, msg)
    }
}

func debugCandidate(_ role: String, direction: String, candidate: String) {
    guard DebugFlags.iceCandidates else { return }

    // Parse candidate string to extract key info
    // Format: "candidate:... typ host/srflx/relay ... address X.X.X.X"
    let parts = candidate.components(separatedBy: " ")

    var candidateType = "unknown"
    var address = "?"
    var port = "?"
    var interface = "?"

    for (i, part) in parts.enumerated() {
        if part == "typ" && i + 1 < parts.count {
            candidateType = parts[i + 1]
        }
        // UDP candidates: "candidate:... 1 udp ... <ip> <port> typ ..."
        // The IP is typically at index 4, port at index 5
        if i == 4 && part.contains(".") || part.contains(":") {
            address = part
        }
        if i == 5 && Int(part) != nil {
            port = part
        }
        // Look for network interface hints
        if part.hasPrefix("network-id") || part.hasPrefix("network-cost") {
            interface = part
        }
    }

    // Categorize address type
    var addressType = ""
    if address.hasPrefix("192.168.") {
        addressType = "[LAN]"
    } else if address.hasPrefix("169.254.") {
        addressType = "[LINK-LOCAL]"
    } else if address.hasPrefix("172.20.10.") {
        addressType = "[HOTSPOT]"
    } else if address.hasPrefix("10.") {
        addressType = "[PRIVATE]"
    } else if address.contains(".local") {
        addressType = "[mDNS]"
    } else if address.contains(":") {
        addressType = "[IPv6]"
    } else {
        addressType = "[OTHER]"
    }

    let msg = "🎯 \(role) \(direction): \(candidateType) \(addressType) \(address):\(port)"
    print(msg)
    os_log("%{public}@", log: iceLog, type: .info, msg)

    // Also log full candidate for debugging if it's interesting
    if addressType == "[LINK-LOCAL]" || addressType == "[mDNS]" || candidateType != "host" {
        let fullMsg = "    └─ full: \(candidate.prefix(120))..."
        print(fullMsg)
        os_log("%{public}@", log: iceLog, type: .info, fullMsg)
    }
}
