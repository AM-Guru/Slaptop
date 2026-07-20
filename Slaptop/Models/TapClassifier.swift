// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

final class TapClassifier {
    private enum Key {
        static let leftCentroid = "calibration.leftCentroid"
        static let rightCentroid = "calibration.rightCentroid"
        static let topCentroid = "calibration.topCentroid"
        static let modelVersion = "calibration.modelVersion"
    }

    /// Stored centroids are discarded when this changes. Version 2 introduced
    /// direction-validated learning; version 3 moved to acceleration-only
    /// detection with measured direction ratios — earlier centroids can
    /// contain gyro-triggered ambient-motion samples.
    static let modelVersion = 3

    /// Runtime gates mirror the calibration ratios but are slightly looser,
    /// leaving an ambiguous band where centroid distance decides.
    private static let sideYawToPitchRollRatio = 0.35
    private static let topPitchRollToYawRatio = 1.5

    /// A matching rotation axis only makes a calibrated location a candidate;
    /// it is not sufficient evidence that the motion was a tap. Captured
    /// laptop lifts, tilts, rotations, and walking motion all passed the axis
    /// gates but remained at least 2.45 in the squared weighted-distance
    /// metric from the location they triggered. Keep a conservative margin
    /// below that nearest false positive so only motion inside the learned tap
    /// shape is accepted.
    private static let maximumCalibratedDistanceSquared = 2.0

    private let defaults: UserDefaults
    private(set) var leftCentroid: ImpactFeatures?
    private(set) var rightCentroid: ImpactFeatures?
    private(set) var topCentroid: ImpactFeatures?

    var isCalibrated: Bool {
        leftCentroid != nil && rightCentroid != nil && topCentroid != nil
    }

    var calibratedSides: Set<TapSide> {
        var sides: Set<TapSide> = []
        if leftCentroid != nil { sides.insert(.left) }
        if rightCentroid != nil { sides.insert(.right) }
        if topCentroid != nil { sides.insert(.top) }
        return sides
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        guard defaults.integer(forKey: Key.modelVersion) == Self.modelVersion else {
            // Centroids from unversioned or older builds predate direction
            // validation and cannot be trusted.
            defaults.removeObject(forKey: Key.leftCentroid)
            defaults.removeObject(forKey: Key.rightCentroid)
            defaults.removeObject(forKey: Key.topCentroid)
            return
        }

        leftCentroid = Self.loadValidatedCentroid(
            forKey: Key.leftCentroid,
            defaults: defaults,
            isPlausible: Self.isPlausibleSideCentroid
        )
        rightCentroid = Self.loadValidatedCentroid(
            forKey: Key.rightCentroid,
            defaults: defaults,
            isPlausible: Self.isPlausibleSideCentroid
        )
        topCentroid = Self.loadValidatedCentroid(
            forKey: Key.topCentroid,
            defaults: defaults,
            isPlausible: Self.isPlausibleTopCentroid
        )

        // Left and right are only distinguishable when their learned yaw
        // directions disagree.
        if let left = leftCentroid, let right = rightCentroid,
           (left.values[5] >= 0) == (right.values[5] >= 0) {
            leftCentroid = nil
            rightCentroid = nil
            defaults.removeObject(forKey: Key.leftCentroid)
            defaults.removeObject(forKey: Key.rightCentroid)
        }
    }

    /// Returns nil when the impact does not resemble any calibrated tap
    /// location, so bumps and ambiguous motion perform no action.
    func classify(_ features: ImpactFeatures) -> TapSide? {
        let pitchAndRoll = hypot(features.values[3], features.values[4])
        let yaw = features.values[5]

        guard let leftCentroid, let rightCentroid else {
            // Uncalibrated: only side taps with a clear yaw component are
            // recognizable. Apple silicon reports positive yaw for a
            // right-edge impact on the tested display orientation;
            // calibration replaces this model- and display-angle-dependent
            // assumption.
            guard abs(yaw) > pitchAndRoll * Self.sideYawToPitchRollRatio else { return nil }
            return yaw >= 0 ? .right : .left
        }

        // A tap may only match a side whose learned yaw direction it shares,
        // and may only match the top when its rotation is clearly pitch/roll
        // based (top strikes carry almost no yaw).
        var candidates: [(TapSide, Double)] = []
        if abs(yaw) > pitchAndRoll * Self.sideYawToPitchRollRatio {
            if (yaw >= 0) == (leftCentroid.values[5] >= 0) {
                candidates.append((.left, weightedDistance(features, leftCentroid)))
            }
            if (yaw >= 0) == (rightCentroid.values[5] >= 0) {
                candidates.append((.right, weightedDistance(features, rightCentroid)))
            }
        }
        if let topCentroid, pitchAndRoll > abs(yaw) * Self.topPitchRollToYawRatio {
            candidates.append((.top, weightedDistance(features, topCentroid)))
        }
        guard
            let closest = candidates.min(by: { $0.1 < $1.1 }),
            closest.1 <= Self.maximumCalibratedDistanceSquared
        else { return nil }
        return closest.0
    }

    func save(samples: [ImpactFeatures], for side: TapSide) {
        guard let centroid = ImpactFeatures.centroid(of: samples) else { return }
        switch side {
        case .left:
            leftCentroid = centroid
            defaults.set(centroid.values, forKey: Key.leftCentroid)
        case .right:
            rightCentroid = centroid
            defaults.set(centroid.values, forKey: Key.rightCentroid)
        case .top:
            topCentroid = centroid
            defaults.set(centroid.values, forKey: Key.topCentroid)
        }
        defaults.set(Self.modelVersion, forKey: Key.modelVersion)
    }

    func reset() {
        leftCentroid = nil
        rightCentroid = nil
        topCentroid = nil
        defaults.removeObject(forKey: Key.leftCentroid)
        defaults.removeObject(forKey: Key.rightCentroid)
        defaults.removeObject(forKey: Key.topCentroid)
        defaults.removeObject(forKey: Key.modelVersion)
    }

    private func weightedDistance(_ lhs: ImpactFeatures, _ rhs: ImpactFeatures) -> Double {
        // Acceleration is measured in g while rotation is degrees/second.
        let weights = [2.0, 2.0, 1.0, 0.03, 0.03, 0.05]
        return zip(zip(lhs.values, rhs.values), weights).reduce(0) { result, item in
            let ((left, right), weight) = item
            let delta = (left - right) * weight
            return result + delta * delta
        }
    }

    private static func loadValidatedCentroid(
        forKey key: String,
        defaults: UserDefaults,
        isPlausible: (ImpactFeatures) -> Bool
    ) -> ImpactFeatures? {
        guard
            let values = defaults.array(forKey: key) as? [Double],
            let centroid = ImpactFeatures(values: values),
            isPlausible(centroid)
        else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return centroid
    }

    private static func isPlausibleSideCentroid(_ centroid: ImpactFeatures) -> Bool {
        abs(centroid.values[5])
            > hypot(centroid.values[3], centroid.values[4]) * sideYawToPitchRollRatio
    }

    private static func isPlausibleTopCentroid(_ centroid: ImpactFeatures) -> Bool {
        hypot(centroid.values[3], centroid.values[4])
            > abs(centroid.values[5]) * topPitchRollToYawRatio
    }
}
