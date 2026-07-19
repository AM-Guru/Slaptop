// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum TapTiming {
    /// Ten accepted impacts per second.
    static let minimumInterval = 0.1
    /// One accepted tap per second.
    static let maximumInterval = 1.0
    /// Preserve the original three-taps-per-second behavior by default while
    /// allowing users to opt into faster custom knock codes.
    static let defaultInterval = 1.0 / 3.0

    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumInterval), maximumInterval)
    }

    static func tapsPerSecond(for interval: Double) -> Double {
        1.0 / clamp(interval)
    }
}
