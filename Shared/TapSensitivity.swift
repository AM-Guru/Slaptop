// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum TapSensitivity {
    static let minimum = 0.05
    static let maximum = 0.50
    /// The gentlest "Firm" setting. Defaulting firm keeps typing and desk
    /// bumps from switching Spaces out of the box; people who want gentler
    /// taps can lower the slider themselves.
    static let defaultThreshold = 0.29
    /// AppleSPU gyroscope reports are degrees/second. The derived gyroscope
    /// scale only tunes baseline adaptation; detection itself triggers on
    /// acceleration alone because ambient desk rotation overlaps tap-level
    /// rotation.
    private static let gyroscopeDegreesPerSecondPerG = 25.0
    /// Version 3 resets previously saved thresholds to the firm default once;
    /// the value remains user-adjustable afterwards.
    static let modelVersion = 3

    static func clamp(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    static func gyroscopeThreshold(for accelerationThreshold: Double) -> Double {
        clamp(accelerationThreshold) * gyroscopeDegreesPerSecondPerG
    }
}
