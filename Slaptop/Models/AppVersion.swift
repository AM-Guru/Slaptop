// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum AppVersion {
    static var displayString: String {
        displayString(from: Bundle.main.infoDictionary ?? [:])
    }

    static func displayString(from infoDictionary: [String: Any]) -> String {
        let version = nonemptyString(
            infoDictionary["CFBundleShortVersionString"]
        ) ?? "1.0"
        guard let build = nonemptyString(infoDictionary["CFBundleVersion"]) else {
            return version
        }
        return "\(version) (\(build))"
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
