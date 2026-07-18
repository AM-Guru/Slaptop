// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

final class SensorDaemon: NSObject, NSXPCListenerDelegate {
    private let sensor = SPUHIDMotionSensor()
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: SensorSession] = [:]

    override init() {
        super.init()
        // The sensor's callbacks are installed once and fan out to every
        // connected session, so a second connection cannot silently steal the
        // event stream from an earlier one.
        sensor.onImpact = { [weak self] detection in
            self?.forEachSession { $0.deliverImpact(detection) }
        }
        sensor.onSample = { [weak self] acceleration, gyroscope, impactMagnitude, timestamp in
            self?.forEachSession {
                $0.deliverSample(
                    acceleration: acceleration,
                    gyroscope: gyroscope,
                    impactMagnitude: impactMagnitude,
                    timestamp: timestamp
                )
            }
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement = CodeSignatureValidator.trustedClientRequirement() {
            // Evaluated by XPC against the peer's audit token on every
            // message; a malformed requirement or mismatched client
            // invalidates the connection.
            connection.setCodeSigningRequirement(requirement)
        } else {
            #if DEBUG
            // Ad-hoc signed local builds have no team identifier to pin.
            guard CodeSignatureValidator.isTrustedSlaptopClient(connection) else {
                NSLog("SlaptopSensorDaemon rejected an untrusted XPC client (pid %d)", connection.processIdentifier)
                return false
            }
            #else
            NSLog("SlaptopSensorDaemon has no team identifier; rejecting all clients.")
            return false
            #endif
        }

        connection.exportedInterface = NSXPCInterface(with: SensorDaemonProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: SensorClientProtocol.self)

        let session = SensorSession(sensor: sensor, connection: connection, daemon: self)
        let identifier = ObjectIdentifier(connection)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self] in
            self?.removeSession(identifier)
        }

        lock.withLock { sessions[identifier] = session }
        connection.resume()
        return true
    }

    func stopSensorIfIdle() {
        let anySessionMonitoring = lock.withLock {
            sessions.values.contains { $0.isMonitoring }
        }
        if !anySessionMonitoring { sensor.stop() }
    }

    private func forEachSession(_ body: (SensorSession) -> Void) {
        let currentSessions = lock.withLock { Array(sessions.values) }
        for session in currentSessions { body(session) }
    }

    private func removeSession(_ identifier: ObjectIdentifier) {
        lock.withLock { _ = sessions.removeValue(forKey: identifier) }
        stopSensorIfIdle()
    }
}

final class SensorSession: NSObject, SensorDaemonProtocol {
    private let sensor: SPUHIDMotionSensor
    private weak var connection: NSXPCConnection?
    private weak var daemon: SensorDaemon?
    private let stateLock = NSLock()
    private var telemetryEnabled = false
    private var monitoring = false

    init(sensor: SPUHIDMotionSensor, connection: NSXPCConnection, daemon: SensorDaemon) {
        self.sensor = sensor
        self.connection = connection
        self.daemon = daemon
        super.init()
    }

    var isMonitoring: Bool {
        stateLock.withLock { monitoring }
    }

    func sensorAvailability(withReply reply: @escaping (Bool, String) -> Void) {
        let available = sensor.isAvailable
        reply(
            available,
            available
                ? "AppleSPU motion sensor found."
                : "No compatible AppleSPU motion sensor was found."
        )
    }

    func startMonitoring(
        sensitivity: Double,
        minimumTapInterval: Double,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        sensor.setSensitivity(sensitivity)
        sensor.setMinimumTapInterval(minimumTapInterval)

        do {
            try sensor.start()
            stateLock.withLock { monitoring = true }
            clientProxy?.sensorStateDidChange(
                isRunning: true,
                message: "Streaming motion sensor data."
            )
            reply(true, "Streaming motion sensor data.")
        } catch {
            stateLock.withLock { monitoring = false }
            daemon?.stopSensorIfIdle()
            clientProxy?.sensorStateDidChange(
                isRunning: false,
                message: error.localizedDescription
            )
            reply(false, error.localizedDescription)
        }
    }

    func setSensitivity(_ sensitivity: Double) {
        sensor.setSensitivity(sensitivity)
    }

    func setMinimumTapInterval(_ interval: Double) {
        sensor.setMinimumTapInterval(interval)
    }

    func setTelemetryEnabled(_ enabled: Bool) {
        stateLock.withLock {
            telemetryEnabled = enabled
        }
    }

    func stopMonitoring(withReply reply: @escaping () -> Void) {
        stateLock.withLock {
            telemetryEnabled = false
            monitoring = false
        }
        daemon?.stopSensorIfIdle()
        clientProxy?.sensorStateDidChange(isRunning: false, message: "Sensor paused.")
        reply()
    }

    func deliverImpact(_ detection: MotionFeatureDetector.Detection) {
        guard isMonitoring, let client = clientProxy else { return }
        client.didDetectImpact(
            features: detection.features.map(NSNumber.init(value:)),
            magnitude: detection.magnitude
        )
    }

    func deliverSample(
        acceleration: SensorVector,
        gyroscope: SensorVector,
        impactMagnitude: Double,
        timestamp: TimeInterval
    ) {
        guard
            stateLock.withLock({ monitoring && telemetryEnabled }),
            let client = clientProxy
        else { return }
        client.didReceiveSensorSample(
            acceleration: [acceleration.x, acceleration.y, acceleration.z].map(NSNumber.init(value:)),
            gyroscope: [gyroscope.x, gyroscope.y, gyroscope.z].map(NSNumber.init(value:)),
            impactMagnitude: impactMagnitude,
            timestamp: timestamp
        )
    }

    private var clientProxy: SensorClientProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { _ in } as? SensorClientProtocol
    }
}
