# Repository Guidelines

## Project Structure & Module Organization
The iOS app lives in `GolfSwingRTC/` with `AppDelegate.swift`, `SceneDelegate.swift`, and `RootViewController.swift` bootstrapping the UI flow. Role-specific controllers (`SenderViewController.swift`, `ReceiverViewController.swift`) manage capture, rendering, and WebRTC peer connections. Signaling helpers (`MPCSignaler.swift`, `SignalMessage.swift`) and debug switches (`DebugFlags.swift`) share the same folder; update them together when changing networking behavior. Assets sit under `GolfSwingRTC/Assets.xcassets`, while localization stubs live in `GolfSwingRTC/Base.lproj`. Tests are split into `GolfSwingRTCTests/` for unit coverage and `GolfSwingRTCUITests/` for launch smoke tests.

## Build, Test, and Development Commands
- `pod install` – sync CocoaPods and generate `GolfSwingRTC.xcworkspace` before opening the project.
- `xcodebuild -workspace GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -configuration Debug build` – compile the app for the current SDK.
- `xcodebuild test -workspace GolfSwingRTC.xcworkspace -scheme GolfSwingRTC -destination 'platform=iOS Simulator,name=iPhone 15'` – run unit and UI tests headlessly.
- `scripts/deploy-both.sh` – build the latest app and install it onto Red and Orange without launching.
- `scripts/launch-both.sh` – launch the installed app on Red (as sender) and Orange (as receiver) simultaneously.
- `scripts/run-dual-automation.sh` – (optional) run the Red/Orange UI tests in parallel to drive both devices automatically after deploying.

## Coding Style & Naming Conventions
Use Swift's default four-space indentation and keep braces on the same line as declarations. Prefer `final class` or `struct` as seen in the controllers and keep member ordering grouped under `// MARK:` headers. Adopt UpperCamelCase for types, lowerCamelCase for properties and functions, and rely on the existing `debug*` helpers instead of raw `print`.

## Testing Guidelines
Extend `GolfSwingRTCTests.swift` with targeted XCTest cases per component (`testSenderReconnects`, etc.) and mirror UI flows in `GolfSwingRTCUITests`. Keep tests deterministic; seed WebRTC inputs with canned SDP blobs when needed. Aim to cover new signaling or media code with at least one unit test and confirm `xcodebuild test` passes before submitting.

## Commit & Pull Request Guidelines
Follow the repo's concise, lower-case commit style (`video stops after 3 seconds`); lead with the affected area when practical. Each PR should describe the scenario, note simulator/device targets, and paste key command output (`xcodebuild test ...`). Link tracking issues when available and attach screenshots or logs when UI or runtime behavior changes.

## Signaling & Configuration Tips
Local-network prompts fire from `RootViewController.triggerLocalNetworkPermission()`; verify this still runs when adjusting onboarding. Update STUN/TURN hosts inside `SenderViewController` together with any receiver-side expectations. Toggle `DebugFlags` thoughtfully and reset verbose options before merging to keep console noise manageable.
