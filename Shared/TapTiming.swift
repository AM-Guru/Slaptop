// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum TapTiming {
    /// Three accepted taps per second.
    static let minimumInterval = 1.0 / 3.0
    /// One accepted tap per second.
    static let maximumInterval = 1.0
    static let defaultInterval = minimumInterval

    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumInterval), maximumInterval)
    }

    static func tapsPerSecond(for interval: Double) -> Double {
        1.0 / clamp(interval)
    }
}
