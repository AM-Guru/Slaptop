// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

struct SensorAxes: Equatable {
    let x: Double
    let y: Double
    let z: Double

    init?(_ numbers: [NSNumber]) {
        guard numbers.count == SensorDataConstants.telemetryVectorCount else { return nil }
        let values = numbers.map(\.doubleValue)
        guard values.allSatisfy(\.isFinite) else { return nil }
        x = values[0]
        y = values[1]
        z = values[2]
    }

    var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }
}

struct LiveSensorSample: Identifiable, Equatable {
    let id: UInt64
    let timestamp: TimeInterval
    let acceleration: SensorAxes
    let gyroscope: SensorAxes
    let impactMagnitude: Double
}
