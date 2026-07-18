// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum MissionControlActionError: LocalizedError {
    case mustRunInstalledApplication
    case accessibilityPermissionRequired
    case keyEventCreationFailed
    case missionControlUnavailable
    case missionControlLaunchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .mustRunInstalledApplication:
            return "Move Slaptop to /Applications before testing Space actions."
        case .accessibilityPermissionRequired:
            return "Allow Slaptop under Privacy & Security → Accessibility so it can switch Spaces, then tap again."
        case .keyEventCreationFailed:
            return "macOS did not accept the Mission Control shortcut keystroke."
        case .missionControlUnavailable:
            return "The macOS Mission Control application could not be found."
        case let .missionControlLaunchFailed(error):
            return "Mission Control could not be launched: \(error.localizedDescription)"
        }
    }
}

/// Performs Space switches by synthesizing the standard Mission Control
/// shortcuts (⌃← / ⌃→). Direct SkyLight space manipulation only updates
/// WindowServer's current-space record without compositing the change on
/// modern macOS, so the supported shortcut path is used instead. This
/// requires the user to grant Accessibility access.
final class MissionControlController {
    static let installedApplicationPath = "/Applications/Slaptop.app"

    private static let leftArrowKeyCode: CGKeyCode = 123
    private static let rightArrowKeyCode: CGKeyCode = 124
    private static let controlKeyCode: CGKeyCode = 59

    private let actionQueue = DispatchQueue(
        label: "guru.am.slaptop.mission-control",
        qos: .userInitiated
    )

    static var isInstalledApplication: Bool {
        isInstalledApplication(at: Bundle.main.bundleURL)
    }

    static func isInstalledApplication(at bundleURL: URL) -> Bool {
        bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path == installedApplicationPath
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the one-time system Accessibility prompt when possible and opens
    /// the Accessibility pane so the user can flip the switch either way.
    static func requestAccessibilityAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        if let paneURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(paneURL)
        }
    }

    func perform(
        _ action: SpaceAction,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard Self.isInstalledApplication else {
            completion(.failure(MissionControlActionError.mustRunInstalledApplication))
            return
        }

        switch action {
        case .launchMissionControl:
            launchMissionControl(completion: completion)
        case .switchLeft, .switchRight:
            actionQueue.async {
                let result = Result {
                    try Self.postSpaceSwitchShortcut(for: action)
                }
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }

    private static func postSpaceSwitchShortcut(for action: SpaceAction) throws {
        guard AXIsProcessTrusted() else {
            throw MissionControlActionError.accessibilityPermissionRequired
        }

        let keyCode = action == .switchRight ? rightArrowKeyCode : leftArrowKeyCode
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let controlDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: controlKeyCode,
                keyDown: true
            ),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
            let controlUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: controlKeyCode,
                keyDown: false
            )
        else {
            throw MissionControlActionError.keyEventCreationFailed
        }

        // The Dock's symbolic-hotkey handler wants a genuine Control press,
        // not just modifier flags on the arrow event. Arrow keys on real
        // hardware also carry the Fn and numeric-pad flags.
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        controlDown.flags = .maskControl
        keyDown.flags = arrowFlags
        keyUp.flags = arrowFlags
        controlUp.flags = []

        controlDown.post(tap: .cghidEventTap)
        usleep(5_000)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        usleep(5_000)
        controlUp.post(tap: .cghidEventTap)
    }

    private func launchMissionControl(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            let workspace = NSWorkspace.shared
            let applicationURL = workspace.urlForApplication(
                withBundleIdentifier: "com.apple.exposelauncher"
            ) ?? URL(fileURLWithPath: "/System/Applications/Mission Control.app")

            guard FileManager.default.fileExists(atPath: applicationURL.path) else {
                completion(.failure(MissionControlActionError.missionControlUnavailable))
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            workspace.openApplication(at: applicationURL, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(MissionControlActionError.missionControlLaunchFailed(error)))
                    } else {
                        completion(.success(()))
                    }
                }
            }
        }
    }
}
