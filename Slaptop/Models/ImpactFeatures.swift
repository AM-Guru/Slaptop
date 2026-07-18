// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

struct ImpactFeatures: Equatable {
    static let expectedCount = SensorServiceConstants.featureCount

    let values: [Double]

    init?(_ numbers: [NSNumber]) {
        let values = numbers.map(\.doubleValue)
        guard values.count == Self.expectedCount, values.allSatisfy(\.isFinite) else {
            return nil
        }
        self.values = values
    }

    init?(values: [Double]) {
        guard values.count == Self.expectedCount, values.allSatisfy(\.isFinite) else {
            return nil
        }
        self.values = values
    }

    static func centroid(of samples: [ImpactFeatures]) -> ImpactFeatures? {
        guard !samples.isEmpty else { return nil }
        var totals = Array(repeating: 0.0, count: expectedCount)
        for sample in samples {
            for index in totals.indices {
                totals[index] += sample.values[index]
            }
        }
        return ImpactFeatures(values: totals.map { $0 / Double(samples.count) })
    }
}

enum CalibrationSampleRejection: Equatable {
    case belowThreshold
    case wrongDirection
}

enum CalibrationSampleValidator {
    /// Measured tap data drives these ratios: side strikes carry a clear yaw
    /// impulse but also strong chassis rocking (pitch/roll often exceeds
    /// yaw), while top-edge strikes have almost no yaw at all. Sides
    /// therefore only need yaw above 0.4× pitch/roll, and top needs
    /// pitch/roll above 2× yaw; the gap between the two rules rejects
    /// genuinely ambiguous samples.
    private static let sideYawToPitchRollRatio = 0.4
    private static let topPitchRollToYawRatio = 2.0

    static func rejection(
        for features: ImpactFeatures,
        magnitude: Double,
        threshold: Double,
        learning side: TapSide,
        opposingSideYaw: Double? = nil
    ) -> CalibrationSampleRejection? {
        guard magnitude.isFinite, magnitude >= threshold else {
            return .belowThreshold
        }

        // The yaw sign of a side strike depends on the model and display
        // angle, so it is learned from the user's own taps rather than fixed;
        // the two sides only have to disagree with each other.
        let pitchAndRoll = hypot(features.values[3], features.values[4])
        let yaw = features.values[5]

        let matchesDirection: Bool
        switch side {
        case .left, .right:
            let opposesOtherSide = opposingSideYaw.map { (yaw >= 0) != ($0 >= 0) } ?? true
            matchesDirection = abs(yaw) > pitchAndRoll * Self.sideYawToPitchRollRatio
                && opposesOtherSide
        case .top:
            matchesDirection = pitchAndRoll > abs(yaw) * Self.topPitchRollToYawRatio
        }
        return matchesDirection ? nil : .wrongDirection
    }

    static func accepts(
        _ features: ImpactFeatures,
        magnitude: Double,
        threshold: Double,
        for side: TapSide,
        opposingSideYaw: Double? = nil
    ) -> Bool {
        rejection(
            for: features,
            magnitude: magnitude,
            threshold: threshold,
            learning: side,
            opposingSideYaw: opposingSideYaw
        ) == nil
    }
}

enum TapSide: String, Codable, CaseIterable, Hashable {
    case left
    case right
    case top

    var label: String { rawValue.capitalized }

    var calibrationTarget: String {
        switch self {
        case .left: return "left side"
        case .right: return "right side"
        case .top: return "top edge"
        }
    }
}

enum SpaceAction: Equatable {
    case switchLeft
    case switchRight
    case launchMissionControl

    var label: String {
        switch self {
        case .switchLeft: return "Switch Space: Left"
        case .switchRight: return "Switch Space: Right"
        case .launchMissionControl: return "Launch Mission Control"
        }
    }

    var symbol: String {
        switch self {
        case .switchLeft: return "arrow.left"
        case .switchRight: return "arrow.right"
        case .launchMissionControl: return "rectangle.3.group"
        }
    }
}

enum TapDirectionPreference: String, CaseIterable {
    case natural
    case inverted

    static let key = "mapping.tapDirection"

    var label: String {
        switch self {
        case .natural: return "Natural"
        case .inverted: return "Inverted"
        }
    }
}

extension TapSide {
    /// Natural moves to the Space on the tapped side; Inverted keeps the
    /// original push-the-content mapping where a left tap moves right.
    func action(for direction: TapDirectionPreference) -> SpaceAction {
        switch self {
        case .left: return direction == .natural ? .switchLeft : .switchRight
        case .right: return direction == .natural ? .switchRight : .switchLeft
        case .top: return .launchMissionControl
        }
    }
}
