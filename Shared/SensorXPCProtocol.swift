// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum SensorServiceConstants {
    static let machServiceName = "guru.am.slaptop.sensor-daemon"
    static let daemonPlistName = "guru.am.slaptop.sensor-daemon.plist"
    static let featureCount = 6
    static let telemetryVectorCount = 3
}

/// Calls made by the menu bar app into the privileged sensor daemon.
@objc protocol SensorDaemonProtocol {
    func sensorAvailability(withReply reply: @escaping (Bool, String) -> Void)
    func startMonitoring(
        sensitivity: Double,
        minimumTapInterval: Double,
        withReply reply: @escaping (Bool, String) -> Void
    )
    func setSensitivity(_ sensitivity: Double)
    func setMinimumTapInterval(_ interval: Double)
    func setTelemetryEnabled(_ enabled: Bool)
    func stopMonitoring(withReply reply: @escaping () -> Void)
}

/// Events sent by the daemon to the connected menu bar app.
@objc protocol SensorClientProtocol {
    func didDetectImpact(features: [NSNumber], magnitude: Double)
    func didReceiveSensorSample(
        acceleration: [NSNumber],
        gyroscope: [NSNumber],
        impactMagnitude: Double,
        timestamp: Double
    )
    func sensorStateDidChange(isRunning: Bool, message: String)
}
