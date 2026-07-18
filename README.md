# Slaptop for macOS

Slaptop is a modern Apple-silicon remake of Kalani Helekunihi's 2005 utility. A left-side tap moves one Space left, a right-side tap moves one Space right, and a top-edge tap launches Mission Control. A "Tap direction" setting offers Natural (default — move toward the tapped side) and Inverted (the classic push-the-content mapping). Space switches work by pressing the standard Mission Control shortcuts (⌃← ⌃→) on your behalf, which works with full-screen apps.

## Website

The project website is available at [slaptop.am.guru](https://slaptop.am.guru). Its dependency-free source lives in [`website/`](website/) and includes a browser port of the animation from Slaptop's About screen.

## Requirements

- Any Apple Silicon device with an integrated screen: MacBook, MacBook Air, MacBook Neo, MacBook Pro, or iMac
- macOS 14 or later
- Xcode 16 or later
- A development signing team for the privileged launch daemon workflow

The AppleSPU sensor is not exposed through a public macOS framework. Slaptop therefore includes a narrowly scoped, user-approved launch daemon that enables motion reporting, reads those reports, and sends impact features only to a code-signed Slaptop client. It has no file or network access logic.

## Build

1. Generate the Xcode project: `xcodegen generate`
2. Open `Slaptop.xcodeproj`.
3. Select the `Slaptop` and `SlaptopSensorDaemon` targets and choose the same Development Team under Signing & Capabilities.
4. Build the `Slaptop` scheme.
5. Copy the built app to `/Applications` before enabling its sensor service. Service Management expects the signed app bundle and its helper to remain at a stable location.

Slaptop intentionally refuses to perform Mission Control actions unless its resolved bundle path is exactly `/Applications/Slaptop.app`. Unit tests may run from Xcode's DerivedData location, but functional sensor and Space-switching tests must use the installed build. This keeps the privileged sensor workflow tied to the canonical installed application.

On a fresh or reset macOS Background Task Management database, `SMAppService` may initially report the bundled daemon as not found. Slaptop verifies the signed-in-bundle plist and executable itself, treats a complete payload as not yet registered, and lets `register()` return the real Service Management error if registration fails.

On a fresh install, Slaptop opens a one-time setup window with its About animation and requests sensor helper approval:

- Background Item approval for the bundled sensor daemon in System Settings > General > Login Items.

The setup window shows a green checkmark when macOS grants sensor access. **Travel Spaces** completes the setup and enables Slaptop after the sensor helper is approved. Existing users with a saved enable/disable preference are not shown onboarding retroactively.

Slaptop switches Spaces by synthesizing the standard Mission Control shortcuts (⌃← and ⌃→), which requires granting Slaptop Accessibility access and keeping those default key bindings enabled. Top-edge taps open the system Mission Control application directly. Direct manipulation of managed Spaces through the private SkyLight API was evaluated but only updates WindowServer's current-space record on modern macOS without compositing the change on screen.

Slaptop synthesizes only those two Mission Control key shortcuts, and only in response to a detected tap. It never moves, warps, clicks, or otherwise takes control of the pointer.

## Calibration

Open Settings from the menu bar, choose **Learn Left**, and tap the left side of the display three times. Repeat with **Learn Right** and **Learn Top**. Calibration is stored locally in UserDefaults and can be reset at any time.

Learning uses the thresholds currently selected by the sensitivity slider and accepts a sample when either the acceleration or the rotation threshold is crossed. Left and Right training accept only yaw-dominant motion, and the two sides must rotate in opposite directions — the sign itself is learned from your taps because it varies by model and display angle. Top training accepts only pitch/roll-dominant motion. Wrong-direction, directionless, and below-threshold impacts leave training progress unchanged and are explained inline in Settings. The button press itself is also ignored during a short arming delay.

Tap detection is edge-triggered — an impulse must rise out of quiet motion, so sustained movement fires at most one action — with a configurable 333–1,000 ms interval to prevent one physical tap from switching multiple Spaces while allowing up to three intentional taps per second. The sensitivity slider adjusts the required motion impulse from 0.05 g (gentle) to 0.50 g (firm), with a 0.29 g default.

Choose **Show Sensor Data** in Settings to see rolling accelerometer, gyroscope, and dynamic-impact graphs. The impact graph draws the active detection threshold and reports each accepted tap, making it possible to distinguish missing sensor reports from a threshold that is too firm for a particular MacBook.

## Architecture

- `Slaptop`: native AppKit status menu with SwiftUI settings/about windows, persisted activation preference, permissions, calibration, classification, and direct Mission Control action dispatch.
- `SlaptopSensorDaemon`: root launch daemon registered with `SMAppService`; reads accelerometer and gyroscope HID reports.
- `Shared`: the small Foundation XPC protocol shared by both processes.

## Distribution note

The sensor path relies on undocumented macOS interfaces, so it may change in future hardware or macOS releases and is not suitable for Mac App Store distribution. A Developer ID build should be hardened, notarized, and tested on every supported MacBook family before distribution.

Pushes to `main` can be built and released by the AM-Guru `macos-build` self-hosted GitHub Actions runner. The release job keeps signing and App Store Connect material in encrypted GitHub Secrets, imports the certificate into an ephemeral keychain, and publishes a notarized `Slaptop.dmg` containing only `Slaptop.app`. See [GitHub release configuration](Distribution/GITHUB_RELEASES.md) for the required protected settings.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sensor-research attribution.

## Contributing

I am open to bug fixes and pull requests from the community. If you find a problem or have a suggestion, please open an issue or pull request—I am very happy to review it and include community improvements that fit the project.

## License

Slaptop is an open-source project licensed under the [MIT License](LICENSE). Within the MIT License's very broad permissions, you are free to use, copy, modify, merge, publish, distribute, sublicense, sell, or otherwise build on this work for personal or commercial purposes.

The MIT License requires copies and substantial portions to retain its copyright and permission notice. Beyond that legal notice requirement, if you use or adapt my work, I ask that you credit Kalani Helekunihi and link back to the [Slaptop repository](https://github.com/AM-Guru/Slaptop) when practical.

The AppleSPU device identifiers and report layout are based on research from `olvvier/apple-silicon-accelerometer`. Its separate MIT copyright and permission notice is preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and must remain with distributions containing that material.
