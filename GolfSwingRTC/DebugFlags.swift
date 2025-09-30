import Foundation

struct DebugFlags {
    // Video rendering debugging
    static let videoRendering = true
    static let videoFrameTracking = false  // Turn off noisy frame logs

    // WebRTC stats debugging
    static let webrtcStats = false  // Turn off since we know WebRTC works
    static let webrtcDetailed = false

    // Network/MPC debugging
    static let networkLogging = false
    static let mpcDetailed = false

    // ICE connection debugging
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