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

    var errorDescription: String? {
        switch self {
        case .mustRunInstalledApplication:
            return "Move Slaptop to /Applications before testing Space actions."
        case .accessibilityPermissionRequired:
            return "Allow Slaptop under Privacy & Security → Accessibility so it can use your Mission Control and Spaces shortcuts, then tap again."
        case .keyEventCreationFailed:
            return "macOS did not accept the configured Mission Control shortcut keystroke."
        }
    }
}

/// Switches Spaces and opens Mission Control by synthesizing the configured
/// Mission Control keyboard shortcuts. Direct SkyLight space manipulation only updates
/// WindowServer's current-space record without compositing the change on
/// modern macOS, so the supported shortcut path is used instead. Users can
/// remap each binding to match their system-wide Mission Control settings.
/// This requires the user to grant Accessibility access.
final class MissionControlController {
    static let installedApplicationPath = "/Applications/Slaptop.app"

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

    /// Opens the source and destination folders needed to install a copy that
    /// was launched directly from the disk image. Service Management cannot
    /// register Slaptop's daemon from a transient `/Volumes` path.
    static func showInstallationFolders() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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
        _ binding: TapKeyBinding,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard Self.isInstalledApplication else {
            completion(.failure(MissionControlActionError.mustRunInstalledApplication))
            return
        }

        actionQueue.async {
            let result = Result {
                try Self.postShortcut(binding)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func postShortcut(_ binding: TapKeyBinding) throws {
        guard AXIsProcessTrusted() else {
            throw MissionControlActionError.accessibilityPermissionRequired
        }

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(binding.keyCode),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(binding.keyCode),
                keyDown: false
            )
        else {
            throw MissionControlActionError.keyEventCreationFailed
        }

        let modifierSpecifications: [(KeyBindingModifiers, CGKeyCode, CGEventFlags)] = [
            (.control, 59, .maskControl),
            (.option, 58, .maskAlternate),
            (.shift, 56, .maskShift),
            (.command, 55, .maskCommand),
        ]
        let selectedModifiers = modifierSpecifications.filter {
            binding.modifiers.contains($0.0)
        }

        var activeFlags: CGEventFlags = []
        var modifierDownEvents: [CGEvent] = []
        for (_, keyCode, flag) in selectedModifiers {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
            ) else {
                throw MissionControlActionError.keyEventCreationFailed
            }
            activeFlags.insert(flag)
            event.flags = activeFlags
            modifierDownEvents.append(event)
        }

        // Arrow keys on real hardware carry the Fn and numeric-pad flags.
        // Dock's symbolic-hotkey handler expects those in addition to genuine
        // modifier key-down events for Mission Control shortcuts.
        var keyFlags = activeFlags
        if (123...126).contains(binding.keyCode) {
            keyFlags.formUnion([.maskSecondaryFn, .maskNumericPad])
        }
        keyDown.flags = keyFlags
        keyUp.flags = keyFlags

        var modifierUpEvents: [CGEvent] = []
        for (_, keyCode, flag) in selectedModifiers.reversed() {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
            ) else {
                throw MissionControlActionError.keyEventCreationFailed
            }
            activeFlags.remove(flag)
            event.flags = activeFlags
            modifierUpEvents.append(event)
        }

        modifierDownEvents.forEach { $0.post(tap: .cghidEventTap) }
        usleep(5_000)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        usleep(5_000)
        modifierUpEvents.forEach { $0.post(tap: .cghidEventTap) }
    }
}
