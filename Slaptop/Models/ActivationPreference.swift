// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum ActivationPreference {
    static let key = "app.shouldEnableOnLaunch"

    static func shouldEnableOnLaunch(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

enum FirstLaunchPreference {
    static let completedKey = "app.didCompleteFirstLaunchSetup"

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: completedKey) != nil {
            return !defaults.bool(forKey: completedKey)
        }

        // Do not show onboarding retroactively to people who already made an
        // explicit enable/disable choice in an earlier Slaptop build.
        return defaults.object(forKey: ActivationPreference.key) == nil
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
    }
}
