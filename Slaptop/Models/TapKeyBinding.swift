// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

struct KeyBindingModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

struct TapKeyBinding: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: KeyBindingModifiers

    var displayString: String {
        let modifierSymbols = [
            modifiers.contains(.control) ? "⌃" : "",
            modifiers.contains(.option) ? "⌥" : "",
            modifiers.contains(.shift) ? "⇧" : "",
            modifiers.contains(.command) ? "⌘" : "",
        ].joined()
        return modifierSymbols + Self.keyName(for: keyCode)
    }

    var accessibilityDescription: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(Self.spokenKeyName(for: keyCode))
        return parts.joined(separator: " ")
    }

    var isValid: Bool {
        keyCode <= 127
    }

    private static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static func spokenKeyName(for keyCode: UInt16) -> String {
        spokenKeyNames[keyCode] ?? keyName(for: keyCode)
    }

    // Hardware key codes are intentionally stored instead of characters so
    // the shortcut keeps referring to the key the user recorded even if the
    // active keyboard layout changes later.
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "Esc", 64: "F17", 71: "Clear", 76: "⌤",
        79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑",
    ]

    private static let spokenKeyNames: [UInt16: String] = [
        24: "Equals", 27: "Minus", 30: "Right Bracket", 33: "Left Bracket",
        36: "Return", 39: "Apostrophe", 41: "Semicolon", 42: "Backslash",
        43: "Comma", 44: "Slash", 47: "Period", 48: "Tab", 50: "Grave Accent",
        51: "Delete", 53: "Escape", 76: "Enter", 117: "Forward Delete",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]
}

struct SpaceKeyBindings: Codable, Equatable, Sendable {
    static let defaultsKey = "mapping.keyBindings"

    var switchLeft: TapKeyBinding
    var switchRight: TapKeyBinding
    var launchMissionControl: TapKeyBinding

    static let standard = Self(
        switchLeft: TapKeyBinding(keyCode: 123, modifiers: .control),
        switchRight: TapKeyBinding(keyCode: 124, modifiers: .control),
        launchMissionControl: TapKeyBinding(keyCode: 126, modifiers: .control)
    )

    func binding(for action: SpaceAction) -> TapKeyBinding {
        switch action {
        case .switchLeft: return switchLeft
        case .switchRight: return switchRight
        case .launchMissionControl: return launchMissionControl
        }
    }

    mutating func set(_ binding: TapKeyBinding, for action: SpaceAction) {
        switch action {
        case .switchLeft: switchLeft = binding
        case .switchRight: switchRight = binding
        case .launchMissionControl: launchMissionControl = binding
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let bindings = try? JSONDecoder().decode(Self.self, from: data),
            bindings.allSatisfy(\.isValid)
        else { return .standard }
        return bindings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private var all: [TapKeyBinding] {
        [switchLeft, switchRight, launchMissionControl]
    }

    private func allSatisfy(_ predicate: (TapKeyBinding) -> Bool) -> Bool {
        all.allSatisfy(predicate)
    }
}
