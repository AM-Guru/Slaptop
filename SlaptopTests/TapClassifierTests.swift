// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import Slaptop

final class TapClassifierTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TapClassifierTests")
        defaults.removePersistentDomain(forName: "TapClassifierTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "TapClassifierTests")
        defaults = nil
        super.tearDown()
    }

    func testTapLocationsMapToExpectedActionsForBothDirections() {
        XCTAssertEqual(TapSide.left.action(for: .natural), .switchLeft)
        XCTAssertEqual(TapSide.right.action(for: .natural), .switchRight)
        XCTAssertEqual(TapSide.left.action(for: .inverted), .switchRight)
        XCTAssertEqual(TapSide.right.action(for: .inverted), .switchLeft)
        XCTAssertEqual(TapSide.top.action(for: .natural), .launchMissionControl)
        XCTAssertEqual(TapSide.top.action(for: .inverted), .launchMissionControl)
    }

    func testTapDirectionPreferenceDefaultsToNaturalAndRoundTrips() {
        XCTAssertNil(defaults.string(forKey: TapDirectionPreference.key))
        XCTAssertEqual(TapDirectionPreference(rawValue: "natural"), .natural)
        XCTAssertEqual(TapDirectionPreference(rawValue: "inverted"), .inverted)
        // Unknown stored values must fall back to the natural default.
        XCTAssertNil(TapDirectionPreference(rawValue: "sideways"))
        XCTAssertEqual(TapDirectionPreference.natural.label, "Natural")
        XCTAssertEqual(TapDirectionPreference.inverted.label, "Inverted")
    }

    func testActionsAreOnlyAvailableToCanonicalInstalledBundle() {
        XCTAssertTrue(
            MissionControlController.isInstalledApplication(
                at: URL(fileURLWithPath: "/Applications/Slaptop.app")
            )
        )
        XCTAssertFalse(
            MissionControlController.isInstalledApplication(
                at: URL(fileURLWithPath: "/tmp/DerivedData/Build/Products/Debug/Slaptop.app")
            )
        )
        XCTAssertFalse(MissionControlController.isInstalledApplication(at: URL(fileURLWithPath: "/Applications/Slaptop Beta.app")))
    }

    func testSustainedMotionEmitsOneDetectionUntilQuietReturns() throws {
        let detector = MotionFeatureDetector()
        detector.setSensitivity(0.29)
        var detectionCount = 0
        detector.onDetection = { _ in detectionCount += 1 }

        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 0)
        detector.consumeGyroscope(.zero, time: 0)

        // Sustained acceleration far above threshold for half a second:
        // exactly one detection, not one per minimum tap interval.
        for step in 1...50 {
            detector.consumeAcceleration(
                SensorVector(x: 0.6, y: 0, z: 1),
                time: Double(step) * 0.01
            )
        }
        XCTAssertEqual(detectionCount, 1)

        // Quiet re-arms the detector and the next impulse is detected.
        for step in 51...55 {
            detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: Double(step) * 0.01)
        }
        detector.consumeAcceleration(SensorVector(x: 0.6, y: 0, z: 1), time: 0.60)
        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 0.66)
        XCTAssertEqual(detectionCount, 2)
    }

    func testBuiltAppContainsSensorServicePayload() {
        XCTAssertTrue(
            SensorServiceController.hasBundledService(),
            "The app must embed both its LaunchDaemon plist and executable helper."
        )
    }

    func testSensorServiceFingerprintChangesWithEmbeddedHelper() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Slaptop.app", isDirectory: true)
        let plistURL = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(SensorServiceConstants.daemonPlistName)"
        )
        let helperURL = bundleURL.appendingPathComponent(
            "Contents/Resources/SlaptopSensorDaemon"
        )
        defer {
            try? FileManager.default.removeItem(
                at: bundleURL.deletingLastPathComponent()
            )
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plist-v1".utf8).write(to: plistURL)
        try Data("helper-v1".utf8).write(to: helperURL)
        let firstFingerprint = try XCTUnwrap(
            SensorServiceController.serviceFingerprint(in: bundleURL)
        )

        try Data("helper-v2".utf8).write(to: helperURL)
        let secondFingerprint = try XCTUnwrap(
            SensorServiceController.serviceFingerprint(in: bundleURL)
        )

        XCTAssertEqual(firstFingerprint.count, 64)
        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
    }

    func testDefaultClassificationUsesYawDirection() throws {
        let classifier = TapClassifier(defaults: defaults)
        let left = try XCTUnwrap(ImpactFeatures(values: [0, 0, 1, 0, 0, -4]))
        let right = try XCTUnwrap(ImpactFeatures(values: [0, 0, 1, 0, 0, 4]))

        XCTAssertEqual(classifier.classify(left), .left)
        XCTAssertEqual(classifier.classify(right), .right)
    }

    func testRotationAloneDoesNotTriggerDetection() {
        // Ambient rotation on a desk overlaps tap-level rotation, so the
        // gyroscope must never trigger a detection by itself.
        let detector = MotionFeatureDetector()
        detector.setSensitivity(0.20)
        var detections: [MotionFeatureDetector.Detection] = []
        detector.onDetection = { detections.append($0) }

        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 1.00)
        detector.consumeGyroscope(.zero, time: 1.00)
        detector.consumeGyroscope(SensorVector(x: 0, y: 20, z: 0), time: 1.01)
        detector.consumeGyroscope(.zero, time: 1.03)

        XCTAssertTrue(detections.isEmpty)
    }

    func testLearningValidatesRotationAxisAndSideConsistency() throws {
        let left = try XCTUnwrap(ImpactFeatures(values: [-0.8, 0.1, 0.5, 2, 1, -8]))
        let right = try XCTUnwrap(ImpactFeatures(values: [0.9, 0.1, 0.5, -2, -1, 7]))
        let top = try XCTUnwrap(ImpactFeatures(values: [0.1, -0.2, 0.1, 1, 7, 0.5]))

        XCTAssertTrue(CalibrationSampleValidator.accepts(left, magnitude: 0.3, threshold: 0.2, for: .left))
        XCTAssertFalse(CalibrationSampleValidator.accepts(left, magnitude: 0.3, threshold: 0.2, for: .top))
        XCTAssertTrue(CalibrationSampleValidator.accepts(top, magnitude: 0.3, threshold: 0.2, for: .top))
        XCTAssertFalse(CalibrationSampleValidator.accepts(top, magnitude: 0.3, threshold: 0.2, for: .left))
        XCTAssertFalse(CalibrationSampleValidator.accepts(top, magnitude: 0.3, threshold: 0.2, for: .right))

        // The yaw sign of a side tap is hardware-dependent and learned, not
        // hardcoded: a negative-yaw sample may teach either side while the
        // opposite side is unknown…
        XCTAssertTrue(CalibrationSampleValidator.accepts(left, magnitude: 0.3, threshold: 0.2, for: .right))
        // …but must rotate opposite to an already-learned other side.
        XCTAssertEqual(
            CalibrationSampleValidator.rejection(
                for: left,
                magnitude: 0.3,
                threshold: 0.2,
                learning: .right,
                opposingSideYaw: -8
            ),
            .wrongDirection
        )
        XCTAssertTrue(
            CalibrationSampleValidator.accepts(
                right,
                magnitude: 0.3,
                threshold: 0.2,
                for: .right,
                opposingSideYaw: -8
            )
        )
    }

    func testCalibrationRejectsImpactsBelowConfiguredThreshold() throws {
        let weakTap = try XCTUnwrap(ImpactFeatures(values: [-0.1, 0, 0, 0.5, 0.5, -2]))
        let directionless = try XCTUnwrap(ImpactFeatures(values: [0, 0.3, 0, 0, 0, 0]))

        XCTAssertEqual(
            CalibrationSampleValidator.rejection(
                for: weakTap,
                magnitude: 0.199,
                threshold: 0.20,
                learning: .left
            ),
            .belowThreshold
        )
        XCTAssertTrue(
            CalibrationSampleValidator.accepts(
                weakTap,
                magnitude: 0.30,
                threshold: 0.30,
                for: .left
            )
        )
        XCTAssertEqual(
            CalibrationSampleValidator.rejection(
                for: directionless,
                magnitude: 0.3,
                threshold: 0.2,
                learning: .top
            ),
            .wrongDirection
        )
    }

    func testDetectionCombinesAccelerationAndGyroscopePeaks() throws {
        let detector = MotionFeatureDetector()
        detector.setSensitivity(0.29)
        var detections: [MotionFeatureDetector.Detection] = []
        detector.onDetection = { detections.append($0) }

        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 1.00)
        detector.consumeGyroscope(.zero, time: 1.00)
        // The acceleration peak arrives first…
        detector.consumeAcceleration(SensorVector(x: 0.5, y: 0, z: 1), time: 1.01)
        // …and the yaw peak a few milliseconds later, once acceleration has
        // already decayed. Both peaks must appear in the feature snapshot.
        detector.consumeGyroscope(SensorVector(x: 0, y: 0, z: 9), time: 1.02)
        detector.consumeAcceleration(SensorVector(x: 0.1, y: 0, z: 1), time: 1.025)
        detector.consumeGyroscope(.zero, time: 1.03)

        XCTAssertEqual(detections.count, 1)
        let detection = try XCTUnwrap(detections.first)
        XCTAssertEqual(detection.features[0], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(detection.features[5], 9, accuracy: 0.000_001)
        XCTAssertEqual(detection.magnitude, 0.5, accuracy: 0.000_001)
    }

    func testDetectionCapturesPerAxisGyroscopeExtrema() throws {
        let detector = MotionFeatureDetector()
        detector.setSensitivity(0.29)
        var detections: [MotionFeatureDetector.Detection] = []
        detector.onDetection = { detections.append($0) }

        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 1.00)
        detector.consumeGyroscope(.zero, time: 1.00)
        detector.consumeAcceleration(SensorVector(x: 0.5, y: 0, z: 1), time: 1.01)
        // The yaw impulse arrives first…
        detector.consumeGyroscope(SensorVector(x: 0, y: 0, z: -8), time: 1.015)
        // …then chassis rocking peaks on pitch while yaw decays. Both axis
        // extrema must survive into the feature snapshot with their signs.
        detector.consumeGyroscope(SensorVector(x: 3, y: 0, z: -1), time: 1.02)
        detector.consumeAcceleration(SensorVector(x: 0.05, y: 0, z: 1), time: 1.025)
        detector.consumeGyroscope(.zero, time: 1.03)

        XCTAssertEqual(detections.count, 1)
        let detection = try XCTUnwrap(detections.first)
        XCTAssertEqual(detection.features[3], 3, accuracy: 0.000_001)
        XCTAssertEqual(detection.features[5], -8, accuracy: 0.000_001)
    }

    func testCalibrationRequiresTheAccelerationThresholdEvenWithStrongRotation() throws {
        // Measured ambient desk rotation reaches 20°/s, overlapping real-tap
        // rotation, so rotation alone can never qualify a calibration sample.
        let ambient = try XCTUnwrap(ImpactFeatures(values: [0.01, 0.02, 0.03, 1, 18, 0.5]))
        XCTAssertEqual(
            CalibrationSampleValidator.rejection(
                for: ambient,
                magnitude: 0.05,
                threshold: 0.2,
                learning: .top
            ),
            .belowThreshold
        )

        // A real top tap carries a clear acceleration impulse (measured
        // 0.44–0.55 g) alongside its pitch rotation.
        let top = try XCTUnwrap(ImpactFeatures(values: [0.1, 0.2, 0.48, -28, 8, 5]))
        XCTAssertTrue(
            CalibrationSampleValidator.accepts(top, magnitude: 0.5, threshold: 0.29, for: .top)
        )
    }

    func testCalibrationPersistsAndClassifiesNearestCentroid() throws {
        let classifier = TapClassifier(defaults: defaults)
        let left = try XCTUnwrap(ImpactFeatures(values: [-0.8, 0.1, 0.5, 2, 1, 8]))
        let right = try XCTUnwrap(ImpactFeatures(values: [0.9, 0.1, 0.5, -2, -1, -7]))
        let top = try XCTUnwrap(ImpactFeatures(values: [0.1, -0.9, 0.4, 1, 7, 0]))
        classifier.save(samples: [left, left, left], for: .left)
        classifier.save(samples: [right, right, right], for: .right)
        classifier.save(samples: [top, top, top], for: .top)

        let restored = TapClassifier(defaults: defaults)
        let observed = try XCTUnwrap(ImpactFeatures(values: [-0.7, 0.12, 0.55, 1.8, 1.1, 7.5]))

        XCTAssertTrue(restored.isCalibrated)
        XCTAssertEqual(restored.calibratedSides, Set(TapSide.allCases))
        XCTAssertEqual(restored.classify(observed), .left)
        XCTAssertEqual(restored.classify(top), .top)
    }

    func testClassifierDiscardsCentroidsFromUnversionedBuilds() {
        // Real centroids saved by a build that predates direction-validated
        // learning. The right centroid's yaw is nearly zero, which made right
        // taps classify as top-edge taps (Mission Control).
        defaults.set([-0.07, -0.15, -0.05, 1.73, 2.33, -5.51], forKey: "calibration.leftCentroid")
        defaults.set([-0.01, 0.07, 0.01, 1.63, 0.83, -0.33], forKey: "calibration.rightCentroid")
        defaults.set([0.0, 0.02, 0.03, -3.9, -1.3, 0.03], forKey: "calibration.topCentroid")

        let classifier = TapClassifier(defaults: defaults)

        XCTAssertFalse(classifier.isCalibrated)
        XCTAssertEqual(classifier.calibratedSides, [])
        XCTAssertNil(defaults.array(forKey: "calibration.rightCentroid"))
    }

    func testClassifierDiscardsImplausibleVersionedCentroids() {
        defaults.set(TapClassifier.modelVersion, forKey: "calibration.modelVersion")
        defaults.set([-0.07, -0.15, -0.05, 1.73, 2.33, -5.51], forKey: "calibration.leftCentroid")
        // Yaw is not dominant, so this cannot be a side centroid.
        defaults.set([-0.01, 0.07, 0.01, 1.63, 0.83, -0.33], forKey: "calibration.rightCentroid")
        defaults.set([0.0, 0.02, 0.03, -3.9, -1.3, 0.03], forKey: "calibration.topCentroid")

        let classifier = TapClassifier(defaults: defaults)

        XCTAssertFalse(classifier.isCalibrated)
        XCTAssertEqual(classifier.calibratedSides, [.left, .top])
        XCTAssertNil(defaults.array(forKey: "calibration.rightCentroid"))
        XCTAssertNotNil(defaults.array(forKey: "calibration.leftCentroid"))
    }

    func testYawDominantTapsCannotClassifyAsTop() throws {
        let classifier = TapClassifier(defaults: defaults)
        let left = try XCTUnwrap(ImpactFeatures(values: [0, 0, 0, 1.7, 2.3, -5.5]))
        let right = try XCTUnwrap(ImpactFeatures(values: [0, 0, 0, 1.6, 0.8, 5.5]))
        let top = try XCTUnwrap(ImpactFeatures(values: [0, 0, 0, -3.9, -1.3, 0]))
        classifier.save(samples: [left], for: .left)
        classifier.save(samples: [right], for: .right)
        classifier.save(samples: [top], for: .top)

        // Yaw-dominant rotation with pitch/roll below half its size: the top
        // centroid is not a candidate, however small its raw distance.
        let rightTap = try XCTUnwrap(ImpactFeatures(values: [0, 0.02, 0.03, 1.0, 0.5, 4.0]))
        XCTAssertEqual(classifier.classify(rightTap), .right)

        // And the reverse: pitch-dominant rotation cannot classify as a side.
        let topTap = try XCTUnwrap(ImpactFeatures(values: [0, 0.02, 0.03, -3.0, -1.0, 0.8]))
        XCTAssertEqual(classifier.classify(topTap), .top)
    }

    func testUncalibratedClassificationIgnoresPitchDominantImpacts() throws {
        let classifier = TapClassifier(defaults: defaults)
        let topLike = try XCTUnwrap(ImpactFeatures(values: [0, 0, 0.3, 1, 7, 0.5]))
        XCTAssertNil(classifier.classify(topLike))
    }

    func testCentroidRejectsMalformedFeatures() {
        XCTAssertNil(ImpactFeatures(values: [1, 2]))
        XCTAssertNil(ImpactFeatures(values: [1, 2, 3, 4, 5, .infinity]))
    }

    func testSensitivityDefaultsToTheGentlestFirmSetting() {
        // 0.29 is the lower edge of the "Firm" band in Settings; users may
        // lower it, but out of the box taps must be deliberate.
        XCTAssertEqual(TapSensitivity.defaultThreshold, 0.29, accuracy: 0.000_001)
        XCTAssertEqual(TapSensitivity.clamp(0.01), 0.05)
        XCTAssertEqual(TapSensitivity.clamp(0.90), 0.50)
        XCTAssertEqual(TapSensitivity.gyroscopeThreshold(for: 0.20), 5, accuracy: 0.000_001)
    }

    func testSensorAxesRejectMalformedTelemetry() {
        XCTAssertNil(SensorAxes([1, 2].map(NSNumber.init(value:))))
        XCTAssertNil(SensorAxes([1, 2, Double.infinity].map(NSNumber.init(value:))))

        let axes = SensorAxes([1, 2, 2].map(NSNumber.init(value:)))
        XCTAssertEqual(axes?.magnitude, 3)
    }

    func testSensorChartsUseStableCalibrationRanges() {
        XCTAssertEqual(SensorChartScale.time, 0...12)
        XCTAssertEqual(SensorChartScale.impact, 0...1)
        XCTAssertEqual(SensorChartScale.acceleration, -2...2)
        XCTAssertEqual(SensorChartScale.gyroscope, -100...100)
    }

    func testSensorMonitoringAndSpaceActionsAreIndependent() {
        XCTAssertFalse(SensorMonitoringPolicy.shouldMonitor(
            isSlaptopEnabled: false,
            isSensorLoggingEnabled: false
        ))
        XCTAssertTrue(SensorMonitoringPolicy.shouldMonitor(
            isSlaptopEnabled: true,
            isSensorLoggingEnabled: false
        ))
        XCTAssertTrue(SensorMonitoringPolicy.shouldMonitor(
            isSlaptopEnabled: false,
            isSensorLoggingEnabled: true
        ))
        XCTAssertFalse(SensorMonitoringPolicy.shouldPerformSpaceAction(isSlaptopEnabled: false))
        XCTAssertTrue(SensorMonitoringPolicy.shouldPerformSpaceAction(isSlaptopEnabled: true))
    }

    func testAppVersionIncludesBundleBuildNumber() {
        XCTAssertEqual(
            AppVersion.displayString(from: [
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "22",
            ]),
            "1.0 (22)"
        )
        XCTAssertEqual(
            AppVersion.displayString(from: ["CFBundleShortVersionString": "1.0"]),
            "1.0"
        )
    }

    func testTapTimingSupportsThreeTapsPerSecond() {
        XCTAssertEqual(TapTiming.defaultInterval, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(TapTiming.tapsPerSecond(for: TapTiming.defaultInterval), 3, accuracy: 0.000_001)
        XCTAssertEqual(TapTiming.clamp(0.1), 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(TapTiming.clamp(2), 1)
    }

    func testSpaceActionLabelsDescribeDirectMissionControlActions() {
        XCTAssertEqual(SpaceAction.switchRight.label, "Switch Space: Right")
        XCTAssertEqual(SpaceAction.switchLeft.label, "Switch Space: Left")
        XCTAssertEqual(SpaceAction.launchMissionControl.label, "Launch Mission Control")
    }

    func testActivationDefaultsOnAndExplicitChoicePersists() {
        XCTAssertTrue(ActivationPreference.shouldEnableOnLaunch(defaults: defaults))

        ActivationPreference.setEnabled(false, defaults: defaults)
        XCTAssertFalse(ActivationPreference.shouldEnableOnLaunch(defaults: defaults))

        ActivationPreference.setEnabled(true, defaults: defaults)
        XCTAssertTrue(ActivationPreference.shouldEnableOnLaunch(defaults: defaults))
    }

    func testFirstLaunchSetupIsOneTimeAndDoesNotAppearRetroactively() {
        XCTAssertTrue(FirstLaunchPreference.shouldPresent(defaults: defaults))

        FirstLaunchPreference.markCompleted(defaults: defaults)
        XCTAssertFalse(FirstLaunchPreference.shouldPresent(defaults: defaults))

        defaults.removeObject(forKey: FirstLaunchPreference.completedKey)
        ActivationPreference.setEnabled(false, defaults: defaults)
        XCTAssertFalse(FirstLaunchPreference.shouldPresent(defaults: defaults))
    }
}
