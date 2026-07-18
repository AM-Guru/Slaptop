// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum SensorChartScale {
    /// Telemetry is delivered at 25 Hz and AppModel retains 300 samples.
    static let time: ClosedRange<Double> = 0...12

    /// Tap sensitivity tops out at 0.5 g; twice that leaves useful headroom
    /// without letting one accidental spike flatten the calibration trace.
    static let impact: ClosedRange<Double> = 0...(TapSensitivity.maximum * 2)

    /// Raw acceleration includes gravity. A ±2 g view keeps normal laptop use
    /// and deliberate calibration taps readable while clipping rare outliers.
    static let acceleration: ClosedRange<Double> = -2...2

    /// Observed calibration taps are generally within ±25 °/s. The wider fixed
    /// domain accommodates firmer taps without continuously rescaling the plot.
    static let gyroscope: ClosedRange<Double> = -100...100
}
