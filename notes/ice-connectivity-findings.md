# ICE Connectivity Findings - Offline WebRTC

**Date:** 2025-12-08

## Problem Statement

GolfSwingRTC uses MultipeerConnectivity (MPC) for signaling and WebRTC for video streaming. MPC works without Wi-Fi infrastructure (via AWDL), but WebRTC ICE negotiation fails when there's no infrastructure Wi-Fi.

## Observed Behavior

From device logs, ICE candidates are generated on both devices:

```
iPhone (red/sender):   169.254.194.48:63012 (link-local)
iPad (orange/receiver): 169.254.6.220:52192 (link-local)
```

ICE pair monitoring shows:
```
[in-progress] local:host 169.254.194.48:63012 (udp) ↔ remote:host 169.254.6.220:52192 (udp) sent:0 recv:0
```

**Key observation:** `sent:0 recv:0` - UDP packets are not getting through despite both addresses being in the same 169.254.0.0/16 subnet.

## Root Cause Analysis

### Why 169.254.x.x ↔ 169.254.x.x Doesn't Work

**Link-local addresses (169.254.0.0/16) require the same Layer 2 broadcast domain** - meaning devices must be on the same physical network segment to communicate.

The /16 subnet mask is misleading because link-local is special:

1. **Link-local is non-routable by design** - packets with 169.254.x.x source/destination are never forwarded by routers. They're only valid on a single network link.

2. **The interfaces are not connected:**
   - iPhone's `169.254.194.48` is bound to `en0` (Wi-Fi interface)
   - iPad's `169.254.6.220` is bound to `en0` (Wi-Fi interface)
   - Without an access point, these `en0` interfaces have **no physical connection**

### Evidence from Logs

Device logs show:
```
interface: en2
```

And for MPC:
```
IPv6#2b5ccfa2%awdl0.50566 tcp
```

**MPC uses `awdl0`** (Apple Wireless Direct Link) which creates an ad-hoc peer-to-peer connection. **WebRTC generates candidates on `en0`/`en2`** which have no physical path when there's no Wi-Fi infrastructure.

### Why MPC Works But WebRTC Doesn't

| Component | Interface | Works Offline? |
|-----------|-----------|----------------|
| MultipeerConnectivity | `awdl0` (AWDL) | Yes - creates ad-hoc link |
| WebRTC ICE | `en0`/`en2` (Wi-Fi) | No - no shared medium |

AWDL (Apple Wireless Direct Link) is Apple's proprietary peer-to-peer Wi-Fi technology. It creates a direct wireless link between devices without needing infrastructure. However, WebRTC's ICE implementation doesn't generate candidates for the `awdl0` interface.

## iOS 18 Related Issues

There was a bug in iOS 18 (fixed August 2024) where `RTCNetworkMonitor::initWithObserver` was causing network interfaces to be excluded due to a missing return value in `nw_path_enumerate_interfaces`. This could potentially affect which interfaces WebRTC sees.

Reference: [Network Monitor excluding network interfaces (iOS 18 Beta)](https://issues.webrtc.org/issues/359245764)

## Potential Solutions

### Option 1: Personal Hotspot (Simplest)

One device creates a hotspot, the other connects to it.

**Pros:**
- Creates a real shared network (172.20.10.x subnet)
- Both devices get routable IP addresses
- WebRTC works normally
- No code changes required (just candidate filtering adjustment)

**Cons:**
- Requires manual user action to enable hotspot
- Uses cellular data (if available)
- Battery drain on hotspot device

### Option 2: Tunnel WebRTC Data Through MPC

Since MPC/AWDL works, tunnel the WebRTC UDP traffic through MPC's stream.

**Pros:**
- Fully offline, no hotspot needed
- Uses existing working MPC connection

**Cons:**
- Complex implementation
- TCP tunneling of UDP adds latency
- Need to implement custom relay logic
- May not achieve real-time video performance

### Option 3: Replace WebRTC Video with MPC Data Stream

Abandon WebRTC for video entirely. Use MPC's data stream to send video frames directly.

**Pros:**
- Simpler than tunneling
- Uses proven working connection
- Full control over encoding/decoding

**Cons:**
- Lose WebRTC's optimized video pipeline
- Must implement own video encoding/compression
- MPC bandwidth may be limiting
- Significant rewrite of video handling

### Option 4: Force WebRTC to Use AWDL Interface

Investigate whether WebRTC can be configured to generate candidates on `awdl0`.

**Pros:**
- Would provide true peer-to-peer without hotspot
- Minimal architecture change

**Cons:**
- May not be possible - AWDL is Apple-proprietary
- WebRTC may intentionally exclude it
- Limited documentation/support

## Research References

- [Can WebRTC Work Without Internet in 2025? - VideoSDK](https://www.videosdk.live/developer-hub/webrtc/can-webrtc-work-without-internet)
- [WebRTC TURN: Why you NEED it and when you DON'T need it](https://bloggeek.me/webrtc-turn/)
- [Network Monitor excluding network interfaces (iOS 18 Beta) - WebRTC Bug Tracker](https://issues.webrtc.org/issues/359245764)
- [WebRTC in Swift - Medium](https://medium.com/@ivanfomenko/webrtc-in-swift-in-simple-words-about-the-complex-d9bfe37d4126)
- [WebRTC without signaling server - GitHub](https://github.com/lesmana/webrtc-without-signaling-server)
- [ICE Candidate Tutorial - GetStream](https://getstream.io/resources/projects/webrtc/basics/ice-candidates/)

## Key Takeaways

1. **Link-local (169.254.x.x) requires same physical network** - the /16 subnet is misleading; these addresses are link-scoped and non-routable.

2. **WebRTC doesn't use AWDL** - even though MPC successfully connects via `awdl0`, WebRTC only generates candidates on standard network interfaces (`en0`, `en2`).

3. **Personal Hotspot is the pragmatic solution** - it creates a real shared network where WebRTC can function normally.

4. **The architecture works** - MPC signaling + WebRTC video is sound when there's a shared network. The limitation is physical layer connectivity, not the software design.

---

# AWDL Video Streaming Research

**Date:** 2025-12-08

## AWDL Bandwidth Capabilities

AWDL (Apple Wireless Direct Link) has sufficient bandwidth for video:

| Metric | Value |
|--------|-------|
| Typical AirDrop speeds | 30-100 Mbps |
| Best observed | 476 Mbps (MacBook → iPhone 11) |
| Theoretical max | 866.7 Mbps (MCS 9, 80MHz, 2 streams) |
| **Video requirement** | **5-10 Mbps** (1080p H.264 @ 30fps) |

**Conclusion:** AWDL has 3-10x more bandwidth than needed for video streaming.

## MPC Video Streaming Approaches

### What Works

1. Capture frames via AVFoundation (`captureOutput(_:didOutput:from:)`)
2. Compress as JPEG (0.75 quality) or H.264
3. Send via `session.send(data, toPeers:, with: .reliable)` or `.unreliable`
4. Using `send()` directly works better than NSStreams for video

### Implementation Example

```swift
// In captureOutput delegate
let jpegData = image.jpegData(compressionQuality: 0.75)
try? session.send(jpegData, toPeers: session.connectedPeers, with: .unreliable)
```

### Performance Reality

| Network Type | Latency |
|--------------|---------|
| Same Wi-Fi network | Minimal delay |
| Peer-to-peer Wi-Fi (AWDL) | "A little (or maybe serious) delay" |

One developer noted P2P speeds were "unexpectedly slow" - suggesting MPC framework overhead may be the limiting factor, not AWDL bandwidth itself.

## Apple's Current Recommendation

Apple recommends **Network framework** over MultipeerConnectivity for new code (see TN3151):

- More control over peer-to-peer via `includesPeerToPeer` property
- Supports both TCP and UDP (UDP better for video)
- Better for defined client/server architecture
- DeviceDiscoveryUI (iOS 16+) for secure discovery

**Network framework approach:** TCP for control channel, UDP for video frames.

## Existing Open Source

[SBMultipeerVideoLive](https://github.com/PandaraWen/SBMultipeerVideoLive) - Camera video streaming over MPC. Uses AVFoundation capture → JPEG compression → MPC send.

## Research References

- [AWDL Research Paper (arxiv)](https://arxiv.org/pdf/1808.03156)
- [AirDrop Speed Discussion - MacRumors](https://forums.macrumors.com/threads/airdrop-speed.2226493/)
- [iOS Video Streaming with MPC - Eyes Japan](https://blog.nowhere.co.jp/archives/20181207-26347.html)
- [SBMultipeerVideoLive - GitHub](https://github.com/PandaraWen/SBMultipeerVideoLive)
- [WWDC22: Device-to-Device with Network Framework](https://developer.apple.com/videos/play/wwdc2022/110339/)
- [Apple TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [An Overview of Apple Wireless Direct - WLAN Professionals](https://wlanprofessionals.com/an-overview-of-apple-wireless-direct/)

---

# Recommendation

**Yes, video over AWDL is viable for offline operation.**

## Recommended Approach

### Step 1: Try MPC First (Lowest Effort)

You already have MPC working for signaling. Test adding video frames via `session.send()`:

1. Capture frames (already doing this with RTCCameraVideoCapturer)
2. Compress to JPEG or use VideoToolbox for H.264
3. Send via MPC `.unreliable` mode
4. Decode and display on receiver

**Why this might be fine:** Golf swing analysis involves slow-motion replay. Some latency in the live preview is acceptable - you're not doing a video call, you're capturing swings to review later.

### Step 2: If MPC Latency Is Unacceptable

Switch to Network framework with `includesPeerToPeer = true`:
- Use UDP for video frames (lower latency than MPC's TCP-based streams)
- More implementation work but better control
- Apple's recommended approach for new code

### Step 3: Keep WebRTC for Infrastructure Networks

When Wi-Fi infrastructure is available, WebRTC works great. Consider:
- Detect network conditions at startup
- Use WebRTC when infrastructure Wi-Fi exists
- Fall back to MPC/Network framework video when offline

## Why NOT Personal Hotspot

- iPads can't create hotspots (iPhone-only feature)
- Two-iPad configuration wouldn't work
- Requires manual user action
- Feels like a workaround, not a solution

## Implementation Complexity Estimate

| Approach | Effort | Latency | Reliability |
|----------|--------|---------|-------------|
| MPC + JPEG frames | Low | Medium-High | Good |
| MPC + H.264 (VideoToolbox) | Medium | Medium | Good |
| Network framework + UDP | High | Low | Good |
| Keep WebRTC + require Wi-Fi | None | Low | Excellent |

---

## Current Code Configuration

Both ViewControllers have:
```swift
config.disableLinkLocalNetworks = false
```

This enables link-local candidate generation, but doesn't solve the underlying physical connectivity issue.
