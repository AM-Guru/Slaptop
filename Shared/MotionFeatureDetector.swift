// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

struct SensorVector: Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = SensorVector(x: 0, y: 0, z: 0)

    static func - (lhs: SensorVector, rhs: SensorVector) -> SensorVector {
        SensorVector(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }
}

final class MotionFeatureDetector {
    struct Detection {
        let features: [Double]
        /// Peak dynamic acceleration in g. Acceleration is the sole trigger:
        /// measured ambient rotation (10–20°/s while a machine sits on a
        /// desk) overlaps real-tap rotation, while real taps — including
        /// top-edge taps — always carry a clear acceleration impulse.
        let magnitude: Double
    }

    private struct Candidate {
        /// Per-axis signed extrema across the candidate window.
        var peakAcceleration: SensorVector
        var peakGyroscope: SensorVector
        /// Largest instantaneous acceleration magnitude, reported to the UI.
        var peakAccelerationMagnitude: Double
    }

    var onDetection: ((Detection) -> Void)?

    private let lock = NSLock()
    private var accelerationBaseline: SensorVector?
    private var gyroscopeBaseline: SensorVector?
    private var latestDynamicAcceleration = SensorVector.zero
    private var latestDynamicGyroscope = SensorVector.zero
    private var sensitivity: Double = TapSensitivity.defaultThreshold
    private var candidate: Candidate?
    private var candidateStartedAt: TimeInterval = 0
    private var lastDetectionAt: TimeInterval = -.infinity
    /// Detection is edge-triggered: a new candidate requires a quiet period
    /// first, so sustained motion (walking with the laptop, a poisoned
    /// baseline) fires at most one detection instead of one every interval.
    private var isArmed = true

    private let accelerationLearningRate = 0.012
    private let gyroscopeLearningRate = 0.025
    private let candidateWindow: TimeInterval = 0.055
    private var minimumTapInterval: TimeInterval = TapTiming.defaultInterval

    func setSensitivity(_ value: Double) {
        lock.withLock {
            sensitivity = TapSensitivity.clamp(value)
        }
    }

    func setMinimumTapInterval(_ value: TimeInterval) {
        lock.withLock {
            minimumTapInterval = TapTiming.clamp(value)
        }
    }

    func reset() {
        lock.withLock {
            accelerationBaseline = nil
            gyroscopeBaseline = nil
            latestDynamicAcceleration = .zero
            latestDynamicGyroscope = .zero
            candidate = nil
            candidateStartedAt = 0
            lastDetectionAt = -.infinity
            isArmed = true
        }
    }

    func consumeGyroscope(
        _ sample: SensorVector,
        time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        var detectionToSend: Detection?

        lock.withLock {
            guard var baseline = gyroscopeBaseline else {
                gyroscopeBaseline = sample
                return
            }

            let dynamic = sample - baseline
            latestDynamicGyroscope = dynamic
            let threshold = TapSensitivity.gyroscopeThreshold(for: sensitivity)

            // The baseline always adapts. Full speed while quiet; a slow leak
            // during motion so a baseline captured mid-movement (or drifted by
            // a lid-angle change) recovers within seconds instead of pinning
            // the dynamic signal above threshold indefinitely.
            let learningRate = dynamic.magnitude < threshold * 0.65
                ? gyroscopeLearningRate
                : gyroscopeLearningRate * 0.15
            baseline.x += (sample.x - baseline.x) * learningRate
            baseline.y += (sample.y - baseline.y) * learningRate
            baseline.z += (sample.z - baseline.z) * learningRate
            gyroscopeBaseline = baseline

            detectionToSend = processCurrentMotion(time: time)
        }

        if let detectionToSend {
            onDetection?(detectionToSend)
        }
    }

    @discardableResult
    func consumeAcceleration(
        _ sample: SensorVector,
        time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double {
        var detectionToSend: Detection?
        var observedMagnitude = 0.0

        lock.withLock {
            guard var baseline = accelerationBaseline else {
                accelerationBaseline = sample
                return
            }

            let dynamic = sample - baseline
            latestDynamicAcceleration = dynamic
            observedMagnitude = dynamic.magnitude

            // Same always-adapting policy as the gyroscope baseline.
            let learningRate = observedMagnitude < sensitivity * 0.65
                ? accelerationLearningRate
                : accelerationLearningRate * 0.15
            baseline.x += (sample.x - baseline.x) * learningRate
            baseline.y += (sample.y - baseline.y) * learningRate
            baseline.z += (sample.z - baseline.z) * learningRate
            accelerationBaseline = baseline

            detectionToSend = processCurrentMotion(time: time)
        }

        if let detectionToSend {
            onDetection?(detectionToSend)
        }
        return observedMagnitude
    }

    /// Detection triggers on the acceleration impulse alone; the rotation
    /// captured alongside it (yaw for side strikes, pitch/roll for top-edge
    /// strikes) feeds classification, not triggering.
    private func processCurrentMotion(time: TimeInterval) -> Detection? {
        let accelerationMagnitude = latestDynamicAcceleration.magnitude
        // Quiet/arming intentionally ignores the gyroscope: ambient rotation
        // on a desk never settles below tap-level thresholds, so requiring
        // gyroscope quiet would leave the detector disarmed and miss most
        // real taps.
        let isQuiet = accelerationMagnitude < sensitivity * 0.45

        if var current = candidate {
            // Each axis keeps its own signed extremum across the window. A
            // tap's translation impulse, its rotation impulse, and any
            // chassis rocking all peak at different instants; any
            // single-instant snapshot loses whichever axis peaked at another
            // time, destroying the direction information calibration and
            // classification rely on.
            current.peakAcceleration = Self.mergeExtrema(
                current.peakAcceleration,
                latestDynamicAcceleration
            )
            current.peakGyroscope = Self.mergeExtrema(
                current.peakGyroscope,
                latestDynamicGyroscope
            )
            current.peakAccelerationMagnitude = max(
                current.peakAccelerationMagnitude,
                accelerationMagnitude
            )
            candidate = current
        } else {
            // Edge-triggered arming: only an impulse that rises out of a
            // quiet state can start a candidate. Sustained motion crosses the
            // threshold continuously and would otherwise emit one detection
            // per minimum interval for as long as it lasts.
            if isQuiet { isArmed = true }
            guard
                isArmed,
                time - lastDetectionAt >= minimumTapInterval,
                accelerationMagnitude >= sensitivity
            else { return nil }
            isArmed = false
            candidateStartedAt = time
            candidate = Candidate(
                peakAcceleration: latestDynamicAcceleration,
                peakGyroscope: latestDynamicGyroscope,
                peakAccelerationMagnitude: accelerationMagnitude
            )
        }

        guard let candidate else { return nil }
        guard time - candidateStartedAt >= candidateWindow || isQuiet else { return nil }

        self.candidate = nil
        // Apply the configured interval between impact onsets, not between the
        // end of this 55 ms feature window and the next onset. Measuring from
        // `time` would silently add the candidate-window duration and make a
        // displayed 100 ms minimum behave like roughly 155 ms.
        lastDetectionAt = candidateStartedAt
        return Detection(
            features: [
                candidate.peakAcceleration.x,
                candidate.peakAcceleration.y,
                candidate.peakAcceleration.z,
                candidate.peakGyroscope.x,
                candidate.peakGyroscope.y,
                candidate.peakGyroscope.z,
            ],
            magnitude: candidate.peakAccelerationMagnitude
        )
    }

    private static func mergeExtrema(
        _ current: SensorVector,
        _ latest: SensorVector
    ) -> SensorVector {
        SensorVector(
            x: abs(latest.x) > abs(current.x) ? latest.x : current.x,
            y: abs(latest.y) > abs(current.y) ? latest.y : current.y,
            z: abs(latest.z) > abs(current.z) ? latest.z : current.z
        )
    }
}
