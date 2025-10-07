# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GolfSwingRTC is an iOS WebRTC application for real-time video streaming between two devices using local network discovery. The app allows one device to act as a sender (camera) and another as a receiver (viewer), specifically designed for golf swing analysis.

## Architecture

### Core Components

- **RootViewController**: Main menu allowing users to choose sender or receiver role
- **SenderViewController**: Captures and streams video using device camera via WebRTC
- **ReceiverViewController**: Receives and displays video stream from sender
- **MPCSignaler**: Handles peer discovery and signaling using MultipeerConnectivity framework
- **SignalMessage**: Codable struct for WebRTC signaling messages (offer/answer/candidate)

### WebRTC Flow

1. **Peer Discovery**: Uses MultipeerConnectivity for local network device discovery
2. **Signaling**: JSON-encoded messages exchanged via MPC for WebRTC negotiation
3. **Video Streaming**: WebRTC peer connection with camera capture on sender, video rendering on receiver
4. **ICE Candidates**: Filtered to LAN-only (192.168.x.x) for local network communication

### Key Design Patterns

- **Role-based Architecture**: Clear separation between sender/receiver responsibilities
- **Delegate Pattern**: RTCPeerConnectionDelegate for WebRTC events
- **Closure-based Callbacks**: MPCSignaler uses closures for message handling
- **Buffering Strategy**: Messages queued until MPC connection established

## Development Commands

### Building
```bash
# Build for iOS Simulator
xcodebuild -workspace ../GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'platform=iOS Simulator,name=iPhone 17' build

# Build for device
xcodebuild -workspace ../GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'generic/platform=iOS' build
```

### Testing
```bash
# Run unit tests
xcodebuild -workspace ../GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run specific test target
xcodebuild -workspace ../GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GolfSwingRTCTests test
```

### Device Deployment

**Physical Device IDs:**
- Red (iPhone): `00008030-0018494221DB802E` - **SENDER/CAMERA**
- Orange (iPad, iOS 18.6.2): `00008030-000C556E2600202E` - **RECEIVER/VIEWER**

**Build for Devices:**
```bash
# Build for Red (iPhone/Sender)
cd .. && xcodebuild -workspace GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'platform=iOS,id=00008030-0018494221DB802E' -derivedDataPath ./DerivedData clean build

# Build for Orange (iPad/Receiver)
cd .. && xcodebuild -workspace GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'platform=iOS,id=00008030-000C556E2600202E' -derivedDataPath ./DerivedData clean build
```

**Deploy to Devices:**
```bash
# Deploy to Red (iPhone) - newer iOS versions
cd .. && xcrun devicectl device install app --device 00008030-0018494221DB802E "DerivedData/Build/Products/Debug-iphoneos/GolfSwingRTC.app"

# Deploy to Orange (iPad) - older iOS versions may need xcodebuild install
cd .. && xcrun devicectl device install app --device 00008030-000C556E2600202E "DerivedData/Build/Products/Debug-iphoneos/GolfSwingRTC.app"

# Alternative deployment method for older iOS
cd .. && xcodebuild -workspace GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'platform=iOS,id=DEVICE_ID' -derivedDataPath ./DerivedData install

```

### Automated red/orange session

Use `scripts/red-orange-session.sh` to deploy the latest build to the red sender
and orange receiver, trigger the "Start" buttons via CoreDevice automation, and
stream device logs into `logs/`.

```bash
cd .. && scripts/red-orange-session.sh
```

Override the default UDIDs by exporting `RED_UDID` and/or `ORANGE_UDID` before
running the script when working with replacement hardware.

### Dependencies
- **WebRTC**: Uses package from https://github.com/stasel/WebRTC @ 140.0.0
- **CocoaPods**: Minimal Podfile setup, dependencies managed via Swift Package Manager

## Important Implementation Details

### Video Rendering
- **Sender**: Uses RTCMTLVideoView for local preview with scaleAspectFill
- **Receiver**: Uses RTCMTLVideoView for remote video with scaleAspectFit
- **Video Track Attachment**: Receiver uses didAdd rtpReceiver delegate method for video track handling

### Network Configuration
- **ICE Servers**: Sender uses empty array (LAN only), Receiver includes STUN server
- **Candidate Filtering**: Sender explicitly filters to 192.168.x.x addresses only
- **Connection Type**: Uses .required encryption for MultipeerConnectivity

### Permissions
- **Camera**: AVCaptureDevice.requestAccess required for sender
- **Local Network**: NWConnection to mDNS group triggers system permission prompt

## File Structure
```
GolfSwingRTC/
├── AppDelegate.swift - Standard iOS app delegate
├── SceneDelegate.swift - iOS 13+ scene management
├── RootViewController.swift - Main menu UI
├── SenderViewController.swift - Camera streaming logic
├── ReceiverViewController.swift - Video receiving logic
├── MPCSignaler.swift - MultipeerConnectivity signaling
├── SignalMessage.swift - WebRTC message types
└── Assets.xcassets/ - App icons and colors
```

## Common Issues
- **Video not displaying**: Check RTCPeerConnectionDelegate.didAdd rtpReceiver implementation
- **Connection failures**: Verify both devices are on same WiFi network and local network permissions granted
- **Camera not working**: Ensure camera permissions granted and device has back camera
