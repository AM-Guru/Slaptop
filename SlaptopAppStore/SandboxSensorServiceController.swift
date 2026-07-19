// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

/// App Store builds read AppleSPU reports in-process. They never install or
/// connect to the privileged sensor daemon used by the Developer ID build.
enum HelperAuthorization: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var label: String {
        switch self {
        case .notRegistered: return "Unavailable"
        case .enabled: return "Sandboxed"
        case .requiresApproval: return "Unavailable"
        case .notFound: return "Sensor unavailable"
        }
    }
}

final class SensorServiceController {
    enum StartResult {
        case running(message: String)
        case daemonRefused(message: String)
        case unreachable(message: String)
    }

    var onImpact: (([NSNumber], Double) -> Void)?
    var onSample: (([NSNumber], [NSNumber], Double, Double) -> Void)?
    var onStateChange: ((Bool, String) -> Void)?

    private let sensor = SPUHIDMotionSensor()
    private let sensorQueue = DispatchQueue(label: "guru.am.slaptop.app-store-sensor", qos: .userInitiated)
    private let stateLock = NSLock()
    private var telemetryEnabled = false
    private var requestGeneration = 0

    init() {
        sensor.onImpact = { [weak self] detection in
            self?.onImpact?(detection.features.map(NSNumber.init(value:)), detection.magnitude)
        }
        sensor.onSample = { [weak self] acceleration, gyroscope, magnitude, timestamp in
            guard let self, self.stateLock.withLock({ self.telemetryEnabled }) else { return }
            self.onSample?(
                [NSNumber(value: acceleration.x), NSNumber(value: acceleration.y), NSNumber(value: acceleration.z)],
                [NSNumber(value: gyroscope.x), NSNumber(value: gyroscope.y), NSNumber(value: gyroscope.z)],
                magnitude,
                timestamp
            )
        }
    }

    deinit {
        sensor.stop()
    }

    var authorization: HelperAuthorization {
        sensor.isAvailable ? .enabled : .notFound
    }

    var registrationNeedsRefresh: Bool { false }

    func register() throws {
        guard sensor.isAvailable else { throw SPUSensorError.sensorNotFound }
    }

    func unregister() throws {
        disconnect()
    }

    func refreshRegistrationIfNeeded(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(sensor.isAvailable ? .success(()) : .failure(SPUSensorError.sensorNotFound))
    }

    func reinstallService(completion: @escaping (Result<Void, Error>) -> Void) {
        disconnect()
        completion(sensor.isAvailable ? .success(()) : .failure(SPUSensorError.sensorNotFound))
    }

    func openApprovalSettings() {}

    func start(
        sensitivity: Double,
        minimumTapInterval: Double,
        completion: @escaping (StartResult) -> Void
    ) {
        sensor.setSensitivity(sensitivity)
        sensor.setMinimumTapInterval(minimumTapInterval)
        let generation = stateLock.withLock { () -> Int in
            requestGeneration += 1
            return requestGeneration
        }
        sensorQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequest(generation) else { return }
            do {
                try self.sensor.start()
                guard self.isCurrentRequest(generation) else {
                    self.sensor.stop()
                    return
                }
                let message = "Listening through sandboxed AppleSPU access."
                self.onStateChange?(true, message)
                completion(.running(message: message))
            } catch {
                completion(.daemonRefused(message: error.localizedDescription))
            }
        }
    }

    func updateSensitivity(_ sensitivity: Double) {
        sensor.setSensitivity(sensitivity)
    }

    func updateMinimumTapInterval(_ interval: Double) {
        sensor.setMinimumTapInterval(interval)
    }

    func setTelemetryEnabled(_ enabled: Bool) {
        stateLock.withLock { telemetryEnabled = enabled }
    }

    func disconnect() {
        stateLock.withLock {
            requestGeneration += 1
            telemetryEnabled = false
        }
        sensorQueue.async { [weak self] in
            guard let self else { return }
            let wasRunning = self.sensor.isRunning
            self.sensor.stop()
            if wasRunning {
                self.onStateChange?(false, "Sensor stopped.")
            }
        }
    }

    private func isCurrentRequest(_ generation: Int) -> Bool {
        stateLock.withLock { requestGeneration == generation }
    }
}
