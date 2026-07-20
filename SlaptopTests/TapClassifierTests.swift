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

    func testSpaceKeyBindingsHaveExpectedMissionControlDefaults() {
        let bindings = SpaceKeyBindings.standard

        XCTAssertEqual(bindings.switchLeft.displayString, "⌃←")
        XCTAssertEqual(bindings.switchRight.displayString, "⌃→")
        XCTAssertEqual(bindings.launchMissionControl.displayString, "⌃↑")
        XCTAssertEqual(bindings.switchLeft.accessibilityDescription, "Control Left Arrow")
        XCTAssertEqual(bindings.launchMissionControl.accessibilityDescription, "Control Up Arrow")
        XCTAssertEqual(TapKeyBinding(keyCode: 10, modifiers: []).displayString, "Key 10")
    }

    func testSpaceKeyBindingsPersistAndRejectInvalidStoredValues() throws {
        var bindings = SpaceKeyBindings.standard
        let commandK = TapKeyBinding(keyCode: 40, modifiers: [.command, .shift])
        bindings.set(commandK, for: .launchMissionControl)
        bindings.save(to: defaults)

        XCTAssertEqual(SpaceKeyBindings.load(from: defaults), bindings)
        XCTAssertEqual(
            SpaceKeyBindings.load(from: defaults).binding(for: .launchMissionControl).displayString,
            "⇧⌘K"
        )

        let invalid = SpaceKeyBindings(
            switchLeft: TapKeyBinding(keyCode: 999, modifiers: []),
            switchRight: bindings.switchRight,
            launchMissionControl: bindings.launchMissionControl
        )
        defaults.set(try JSONEncoder().encode(invalid), forKey: SpaceKeyBindings.defaultsKey)
        XCTAssertEqual(SpaceKeyBindings.load(from: defaults), .standard)
    }

    @MainActor
    func testAppModelUpdatesAndRestoresKeyBindings() {
        let model = AppModel(defaults: defaults, automaticallyEnable: false)
        let custom = TapKeyBinding(keyCode: 0, modifiers: [.control, .option])

        model.setKeyBinding(custom, for: .switchLeft)
        XCTAssertEqual(model.keyBinding(for: .switchLeft), custom)
        XCTAssertEqual(SpaceKeyBindings.load(from: defaults).switchLeft, custom)

        model.restoreDefaultKeyBindings()
        XCTAssertEqual(model.keyBindings, .standard)
        XCTAssertNil(defaults.data(forKey: SpaceKeyBindings.defaultsKey))
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

    func testApplicationInstallerCopiesValidatedBundleWithoutReplacingIt() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlaptopInstallerTests-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = temporaryDirectory
            .appendingPathComponent("Slaptop.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            try AppInstallationManager.installCurrentApplication(
                from: Bundle.main.bundleURL,
                to: destinationURL
            ),
            .installed
        )
        XCTAssertEqual(Bundle(url: destinationURL)?.bundleIdentifier, "guru.am.slaptop")

        // A second request must reuse the validated installed copy rather than
        // deleting or replacing it.
        XCTAssertEqual(
            try AppInstallationManager.installCurrentApplication(
                from: Bundle.main.bundleURL,
                to: destinationURL
            ),
            .existingInstallation
        )
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

    func testMotionDetectorAcceptsDistinctImpactsOneHundredMillisecondsApart() {
        let detector = MotionFeatureDetector()
        detector.setSensitivity(0.29)
        detector.setMinimumTapInterval(0.1)
        var detectionCount = 0
        detector.onDetection = { _ in detectionCount += 1 }

        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 0)
        detector.consumeGyroscope(.zero, time: 0)

        detector.consumeAcceleration(SensorVector(x: 0.6, y: 0, z: 1), time: 0.01)
        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 0.07)
        XCTAssertEqual(detectionCount, 1)
        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 0.08)

        // This onset is only 90 ms after the first and is ignored.
        detector.consumeAcceleration(SensorVector(x: 0.6, y: 0, z: 1), time: 0.10)
        XCTAssertEqual(detectionCount, 1)

        // The same distinct impulse becomes eligible exactly 100 ms after the
        // previous impact began, independent of its 55 ms feature window.
        detector.consumeAcceleration(SensorVector(x: 0.6, y: 0, z: 1), time: 0.11)
        detector.consumeAcceleration(SensorVector(x: 0, y: 0, z: 1), time: 0.17)
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

    func testClassifierRejectsCapturedLaptopLiftAndTiltFalsePositives() throws {
        let classifier = try makeClassifierFromCapturedCalibration()
        let capturedFalseImpacts = [
            [0.031261, -0.287154, 0.308904, 77.937854, 7.700921, -1.672320],
            [-0.045638, 0.177872, -0.295939, -64.440671, -15.250134, 2.994139],
            [0.035006, -0.283636, 0.387302, 109.585114, 11.820242, -3.192120],
            [-0.069739, 0.270042, -0.359711, -45.049475, 5.676884, 2.639529],
            [0.043581, -0.287094, 0.288622, 119.046192, 12.372131, -3.163202],
            [-0.037571, 0.189032, -0.349678, -69.974269, -12.831867, 0.935194],
        ]

        for values in capturedFalseImpacts {
            XCTAssertNil(
                classifier.classify(try XCTUnwrap(ImpactFeatures(values: values))),
                "Lifting or returning the laptop to level must not launch Mission Control."
            )
        }
    }

    func testClassifierRejectsCapturedLaptopRotationFalsePositives() throws {
        let classifier = try makeClassifierFromCapturedCalibration()
        let capturedFalseImpacts = [
            [0.301204, -0.119628, 0.281706, 5.904926, 75.225014, 19.831334],
            [0.239169, 0.028595, 0.348403, -16.080848, 90.141596, 10.645860],
            [-0.188487, 0.082636, -0.458017, -40.416084, -80.106668, -16.544381],
            [-0.288863, 0.107683, -0.334931, -4.484177, -97.499555, -13.851733],
            [0.250370, 0.073526, 0.407443, -19.781258, 82.354923, 6.487234],
            [-0.172263, -0.095094, -0.425229, -30.511185, -50.646267, -3.237392],
            [-0.343353, 0.078478, -0.273725, -7.172788, -93.789264, -10.533166],
            [0.257823, 0.063422, 0.262913, 3.908914, -22.413480, 4.611305],
            [-0.154906, 0.090305, -0.433637, -12.904562, -57.602738, 6.371140],
        ]

        for values in capturedFalseImpacts {
            XCTAssertNil(
                classifier.classify(try XCTUnwrap(ImpactFeatures(values: values))),
                "Rotating a held laptop must not launch Mission Control."
            )
        }
    }

    func testClassifierRejectsCapturedWalkingShakeFalsePositives() throws {
        let classifier = try makeClassifierFromCapturedCalibration()
        let capturedFalseImpacts = [
            [-0.363242, 0.112696, 0.048774, 10.665598, -2.489726, 14.722963],
            [-0.511660, 0.243460, -0.059405, 15.716508, 3.439657, 20.593192],
            [0.307949, -0.042816, 0.051983, -21.098474, -9.667621, -14.305916],
            [-0.563917, 0.109791, -0.082231, 13.012421, -8.949830, 20.909609],
            [-0.519347, 0.118140, 0.055373, 7.192311, 7.980883, -4.727329],
            [-0.593005, -0.205687, -0.032719, 11.150418, -12.548638, 3.687305],
        ]

        for values in capturedFalseImpacts {
            XCTAssertNil(
                classifier.classify(try XCTUnwrap(ImpactFeatures(values: values))),
                "Walking-style laptop motion must not switch Spaces."
            )
        }
    }

    func testCapturedLapUseBurstDoesNotTriggerDetector() {
        let detector = MotionFeatureDetector()
        detector.setSensitivity(0.29)
        var detections: [MotionFeatureDetector.Detection] = []
        detector.onDetection = { detections.append($0) }
        let samples: [(SensorVector, SensorVector)] = [
            (.init(x: 0.002502, y: -0.004013, z: -1.000702), .init(x: -7.080078, y: -0.122070, z: -0.854492)),
            (.init(x: 0.003845, y: 0.004257, z: -0.998871), .init(x: -7.507324, y: 0, z: -0.671387)),
            (.init(x: 0.035202, y: 0.032257, z: -1.064194), .init(x: -6.835938, y: 10.253906, z: 2.563477)),
            (.init(x: 0.025101, y: 0.029465, z: -1.019257), .init(x: -7.751465, y: 12.512207, z: 2.502441)),
            (.init(x: -0.022217, y: -0.006149, z: -0.852753), .init(x: -12.084961, y: -6.713867, z: -5.493164)),
            (.init(x: 0.041214, y: 0.047699, z: -0.935623), .init(x: -12.878418, y: -14.099121, z: -8.911133)),
            (.init(x: 0.026871, y: 0.077011, z: -0.959381), .init(x: -17.089844, y: -15.075684, z: -11.108398)),
            (.init(x: 0.036514, y: 0.061661, z: -1.033218), .init(x: -14.709473, y: -11.962891, z: -9.887695)),
            (.init(x: -0.045303, y: -0.050461, z: -1.055862), .init(x: -3.356934, y: -8.605957, z: 0.427246)),
            (.init(x: -0.034286, y: -0.111099, z: -1.064987), .init(x: 9.521484, y: -9.399414, z: -2.441406)),
            (.init(x: -0.037170, y: -0.009583, z: -1.094421), .init(x: 11.413574, y: 1.831055, z: -3.723145)),
            (.init(x: -0.034378, y: 0.028397, z: -1.032959), .init(x: 8.972168, y: 6.042480, z: -3.662109)),
        ]

        for (index, sample) in samples.enumerated() {
            let time = Double(index) * 0.04
            detector.consumeAcceleration(sample.0, time: time)
            detector.consumeGyroscope(sample.1, time: time)
        }

        XCTAssertTrue(detections.isEmpty)
    }

    func testUncalibratedClassificationIgnoresPitchDominantImpacts() throws {
        let classifier = TapClassifier(defaults: defaults)
        let topLike = try XCTUnwrap(ImpactFeatures(values: [0, 0, 0.3, 1, 7, 0.5]))
        XCTAssertNil(classifier.classify(topLike))
    }

    func testUpdateReleaseTagParsingUsesTrailingBuildNumber() {
        XCTAssertEqual(AppUpdater.buildNumber(fromTag: "v1.0-build.27"), 27)
        XCTAssertEqual(AppUpdater.buildNumber(fromTag: "v2.3-build.104"), 104)
        XCTAssertNil(AppUpdater.buildNumber(fromTag: "v1.0"))
        XCTAssertNil(AppUpdater.buildNumber(fromTag: "v1.0-build."))
        XCTAssertNil(AppUpdater.buildNumber(fromTag: "v1.0-build.12beta"))
    }

    func testUpdateInstallerRequiresAnExactNumericBundleBuild() throws {
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Slaptop-updater-test-\(UUID().uuidString).app")
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: applicationURL) }

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let validPlist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "27"],
            format: .binary,
            options: 0
        )
        try validPlist.write(to: infoPlistURL)
        XCTAssertEqual(try AppUpdateInstaller.buildNumber(of: applicationURL), 27)

        let invalidPlist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "27beta"],
            format: .binary,
            options: 0
        )
        try invalidPlist.write(to: infoPlistURL, options: .atomic)
        XCTAssertThrowsError(try AppUpdateInstaller.buildNumber(of: applicationURL))
    }

    func testUpdateInstallerRequiresGatekeeperToReportNotarization() throws {
        func assessment(verdict: Bool, source: String) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: [
                    "assessment:verdict": verdict,
                    "assessment:authority": ["assessment:authority:source": source],
                ],
                format: .xml,
                options: 0
            )
        }

        XCTAssertTrue(AppUpdateInstaller.isNotarizedGatekeeperAssessment(
            try assessment(verdict: true, source: "Notarized Developer ID")
        ))
        XCTAssertFalse(AppUpdateInstaller.isNotarizedGatekeeperAssessment(
            try assessment(verdict: true, source: "Developer ID")
        ))
        XCTAssertFalse(AppUpdateInstaller.isNotarizedGatekeeperAssessment(
            try assessment(verdict: false, source: "Notarized Developer ID")
        ))
        XCTAssertFalse(AppUpdateInstaller.isNotarizedGatekeeperAssessment(Data("not a plist".utf8)))
    }

    func testAutomaticUpdateChecksFollowTheChosenFrequency() {
        let now = Date()
        XCTAssertFalse(AppUpdater.isAutomaticCheckDue(frequency: .manual, lastCheckedAt: nil, now: now))
        XCTAssertTrue(AppUpdater.isAutomaticCheckDue(frequency: .daily, lastCheckedAt: nil, now: now))
        XCTAssertFalse(AppUpdater.isAutomaticCheckDue(
            frequency: .daily,
            lastCheckedAt: now.addingTimeInterval(-3_600),
            now: now
        ))
        XCTAssertTrue(AppUpdater.isAutomaticCheckDue(
            frequency: .daily,
            lastCheckedAt: now.addingTimeInterval(-90_000),
            now: now
        ))
        XCTAssertFalse(AppUpdater.isAutomaticCheckDue(
            frequency: .weekly,
            lastCheckedAt: now.addingTimeInterval(-90_000),
            now: now
        ))
        XCTAssertTrue(AppUpdater.isAutomaticCheckDue(
            frequency: .weekly,
            lastCheckedAt: now.addingTimeInterval(-700_000),
            now: now
        ))
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

    func testTapTimingSupportsFastKnockCodesAndPreservesTheExistingDefault() {
        XCTAssertEqual(TapTiming.minimumInterval, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(TapTiming.defaultInterval, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(TapTiming.tapsPerSecond(for: TapTiming.defaultInterval), 3, accuracy: 0.000_001)
        XCTAssertEqual(TapTiming.tapsPerSecond(for: TapTiming.minimumInterval), 10, accuracy: 0.000_001)
        XCTAssertEqual(TapTiming.clamp(0.05), 0.1, accuracy: 0.000_001)
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

    func testCustomGestureMatcherLearnsMotionShapeAndRhythm() throws {
        let pattern = makeCustomGesturePattern(name: "Knock Code")
        let observed = sample(
            first: [0.51, 0.09, 0.2, 2.1, 0.9, 8.2],
            second: [-0.21, 0.58, 0.11, -1.1, 5.1, 0.6],
            interval: 0.43
        ).events

        XCTAssertEqual(
            CustomGestureMatcher.bestFullMatch(for: observed, among: [pattern])?.id,
            pattern.id
        )
        XCTAssertEqual(
            CustomGestureMatcher.matchingPrefixes(
                for: Array(observed.prefix(1)),
                among: [pattern]
            ).map(\.id),
            [pattern.id]
        )

        var wrongMotion = observed
        wrongMotion[0] = CustomGestureEvent(
            features: [-1.0, 0.09, 0.2, 2.1, 0.9, 8.2],
            intervalSincePrevious: 0
        )
        XCTAssertNil(CustomGestureMatcher.bestFullMatch(for: wrongMotion, among: [pattern]))

        var wrongRhythm = observed
        wrongRhythm[1] = CustomGestureEvent(
            features: wrongRhythm[1].features,
            intervalSincePrevious: 0.9
        )
        XCTAssertNil(CustomGestureMatcher.bestFullMatch(for: wrongRhythm, among: [pattern]))
    }

    func testCustomGestureTrainingRequiresConsistentImpactCountsAndPerformances() {
        let first = sample(
            first: [0.5, 0.1, 0.2, 2, 1, 8],
            second: [-0.2, 0.6, 0.1, -1, 5, 0.5],
            interval: 0.42
        )
        let similar = sample(
            first: [0.52, 0.08, 0.21, 2.2, 0.8, 8.4],
            second: [-0.18, 0.62, 0.09, -0.8, 5.3, 0.4],
            interval: 0.46
        )
        let different = sample(
            first: [-1.0, 0.08, 0.21, 2.2, 0.8, 8.4],
            second: [-0.18, 0.62, 0.09, -0.8, 5.3, 0.4],
            interval: 0.46
        )
        let oneImpact = CustomGestureSample(events: [similar.events[0]])

        XCTAssertTrue(CustomGestureMatcher.samplesAreConsistent(similar, with: [first]))
        XCTAssertFalse(CustomGestureMatcher.samplesAreConsistent(different, with: [first]))
        XCTAssertFalse(CustomGestureMatcher.samplesAreConsistent(oneImpact, with: [first]))
    }

    func testAnyNumberOfCustomGesturePatternsPersistWithTheirActions() throws {
        let patterns = (0..<24).map { index -> CustomGesturePattern in
            let action: CustomGestureAction = index.isMultiple(of: 2)
                ? .keyboardShortcut(TapKeyBinding(keyCode: UInt16(index), modifiers: .command))
                : .typeText("Text \(index)")
            return makeCustomGesturePattern(name: "Pattern \(index)", action: action)
        }
        CustomGestureStore.save(patterns, to: defaults)

        XCTAssertEqual(CustomGestureStore.load(from: defaults), patterns)
        XCTAssertEqual(CustomGestureStore.load(from: defaults).count, 24)

        let invalid = CustomGesturePattern(
            id: UUID(),
            name: "Only trained twice",
            action: .typeText("No"),
            samples: Array(patterns[0].samples.prefix(2))
        )
        defaults.set(
            try JSONEncoder().encode([patterns[0], invalid]),
            forKey: CustomGestureStore.defaultsKey
        )
        XCTAssertEqual(CustomGestureStore.load(from: defaults), [patterns[0]])
    }

    @MainActor
    func testCustomGestureMetadataCanBeEditedAndDeleted() {
        let pattern = makeCustomGesturePattern(name: "Original")
        CustomGestureStore.save([pattern], to: defaults)
        let model = AppModel(defaults: defaults, automaticallyEnable: false)
        let newAction = CustomGestureAction.typeText("Hello from Slaptop")

        model.updateCustomGesture(id: pattern.id, name: "Greeting", action: newAction)

        XCTAssertEqual(model.customGesturePatterns[0].name, "Greeting")
        XCTAssertEqual(model.customGesturePatterns[0].action, newAction)
        XCTAssertEqual(CustomGestureStore.load(from: defaults), model.customGesturePatterns)

        model.deleteCustomGesture(id: pattern.id)
        XCTAssertTrue(model.customGesturePatterns.isEmpty)
        XCTAssertTrue(CustomGestureStore.load(from: defaults).isEmpty)
    }

    private func makeCustomGesturePattern(
        name: String,
        action: CustomGestureAction = .keyboardShortcut(
            TapKeyBinding(keyCode: 40, modifiers: [.command, .shift])
        )
    ) -> CustomGesturePattern {
        CustomGesturePattern(
            id: UUID(),
            name: name,
            action: action,
            samples: [
                sample(
                    first: [0.5, 0.1, 0.2, 2, 1, 8],
                    second: [-0.2, 0.6, 0.1, -1, 5, 0.5],
                    interval: 0.42
                ),
                sample(
                    first: [0.52, 0.08, 0.21, 2.2, 0.8, 8.4],
                    second: [-0.18, 0.62, 0.09, -0.8, 5.3, 0.4],
                    interval: 0.46
                ),
                sample(
                    first: [0.48, 0.12, 0.19, 1.8, 1.1, 7.7],
                    second: [-0.22, 0.57, 0.12, -1.2, 4.8, 0.6],
                    interval: 0.39
                ),
            ]
        )
    }

    private func makeClassifierFromCapturedCalibration() throws -> TapClassifier {
        let classifier = TapClassifier(defaults: defaults)
        let left = try XCTUnwrap(ImpactFeatures(values: [
            -0.294890, -0.396354, -0.440375, 1.713031, 29.210821, -19.025937,
        ]))
        let right = try XCTUnwrap(ImpactFeatures(values: [
            0.414815, 0.309178, 0.211496, -7.268363, -10.585376, 19.001730,
        ]))
        let top = try XCTUnwrap(ImpactFeatures(values: [
            0.121883, 0.537680, 1.290183, -53.751897, -4.747984, 7.065939,
        ]))
        classifier.save(samples: [left], for: .left)
        classifier.save(samples: [right], for: .right)
        classifier.save(samples: [top], for: .top)
        return classifier
    }

    private func sample(
        first: [Double],
        second: [Double],
        interval: TimeInterval
    ) -> CustomGestureSample {
        CustomGestureSample(events: [
            CustomGestureEvent(features: first, intervalSincePrevious: 0),
            CustomGestureEvent(features: second, intervalSincePrevious: interval),
        ])
    }
}
