// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

enum SensorMonitoringPolicy {
    static func shouldMonitor(
        isSlaptopEnabled: Bool,
        isSensorLoggingEnabled: Bool
    ) -> Bool {
        isSlaptopEnabled || isSensorLoggingEnabled
    }

    static func shouldPerformSpaceAction(isSlaptopEnabled: Bool) -> Bool {
        isSlaptopEnabled
    }
}
