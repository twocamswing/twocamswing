# Offline Automation Plan

Goal: Automate the cycle of deploying GolfSwingRTC to the Red (sender) and Orange (receiver) devices, launching both roles, and validating the offline (no infrastructure Wi‑Fi) peer connection.

## Current Building Blocks

- `scripts/deploy-both.sh`: Builds the app (Debug) once, then runs `xcodebuild install` for sender (Red) and receiver (Orange). Requires device UDIDs (defaults already wired).
- `scripts/launch-both.sh`: Uses `xcrun devicectl device process launch` to start the installed app on both devices in parallel, passing `DEVICECTL_CHILD_AUTO_ROLE=sender/receiver` so each instance knows its role.
- `scripts/run-dual-automation.sh`: Runs the UITests (`testStartSenderFlow`, `testStartReceiverFlow`) against each device simultaneously via `xcodebuild test-without-building`.
- `scripts/capture-logs.sh` and `scripts/red-orange-session.sh`: Existing diagnostics helpers for tailing device logs.

## Missing Piece: Wi‑Fi Control

To simulate the driving-range scenario, we must:
1. Join both devices to `BE37 Hyperoptic 1Gb Fibre 5Ghz Wifi` to deploy/build and satisfy certificate validation.
2. After installation, drop infrastructure Wi‑Fi (while keeping Wi-Fi radio on so AWDL stays up) before launching sender/receiver.

There’s no Wi‑Fi toggling in current scripts, and `devicectl` doesn’t expose a network API. Need a CLI such as `cfgutil` (Apple Configurator) or a custom MDM/Shortcut to script network changes.

## Proposed Automation Flow

1. **Prereq**: Install Apple Configurator’s command-line tools (`cfgutil`) on the Mac. Verify commands:
   - `cfgutil --ecid <UDID> wifi --list`
   - `cfgutil --ecid <UDID> joinWiFi --ssid "BE37 Hyperoptic 1Gb Fibre 5Ghz Wifi" --password <PASSWORD>`
   - `cfgutil --ecid <UDID> forgetWiFi --ssid "BE37 Hyperoptic 1Gb Fibre 5Ghz Wifi"` or other disconnect command.

2. **Script** `scripts/offline-cycle.sh` (to be written):
   - Join both devices to BE37 using `cfgutil`.
   - Run `scripts/deploy-both.sh` to build/install.
   - Optionally `scripts/launch-both.sh` once while connected so the first run satisfies provisioning checks.
   - Use `cfgutil` to disable/forget the BE37 network (and optionally connect to personal hotspot / leave Wi-Fi on but unjoined).
   - Call `scripts/launch-both.sh` again (or automate taps via `scripts/run-dual-automation.sh`) to start sender/receiver offline.
   - Optionally run `scripts/capture-logs.sh` to gather logs while the session runs.

3. **Validation**: Extend UITest coverage (or add a new automation script) to confirm remote video arrives offline. That may include reading WebRTC stats or waiting for a particular log line.

## Next Steps

- Install `cfgutil` and confirm it can join/leave the BE37 network for both devices via command line.
- Once network control works, implement `scripts/offline-cycle.sh` using the steps above.
- Integrate logging/UITest steps to produce pass/fail output.

