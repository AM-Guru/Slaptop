// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import CryptoKit
import Foundation
import ServiceManagement

enum HelperAuthorization: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var label: String {
        switch self {
        case .notRegistered: return "Not installed"
        case .enabled: return "Approved"
        case .requiresApproval: return "Needs approval"
        case .notFound: return "Helper missing"
        }
    }
}

final class SensorClientReceiver: NSObject, SensorClientProtocol {
    var onImpact: (([NSNumber], Double) -> Void)?
    var onSample: (([NSNumber], [NSNumber], Double, Double) -> Void)?
    var onStateChange: ((Bool, String) -> Void)?

    func didDetectImpact(features: [NSNumber], magnitude: Double) {
        onImpact?(features, magnitude)
    }

    func didReceiveSensorSample(
        acceleration: [NSNumber],
        gyroscope: [NSNumber],
        impactMagnitude: Double,
        timestamp: Double
    ) {
        onSample?(acceleration, gyroscope, impactMagnitude, timestamp)
    }

    func sensorStateDidChange(isRunning: Bool, message: String) {
        onStateChange?(isRunning, message)
    }
}

final class SensorServiceController {
    private static let daemonPlistRelativePath = "Contents/Library/LaunchDaemons/\(SensorServiceConstants.daemonPlistName)"
    private static let helperRelativePath = "Contents/Resources/SlaptopSensorDaemon"
    private static let registeredServiceFingerprintKey = "sensor.registeredServiceFingerprint"
    private static let legacyRegisteredBuildKey = "sensor.registeredAppBuild"

    var onImpact: (([NSNumber], Double) -> Void)? {
        didSet { receiver.onImpact = onImpact }
    }

    var onStateChange: ((Bool, String) -> Void)? {
        didSet { receiver.onStateChange = onStateChange }
    }

    var onSample: (([NSNumber], [NSNumber], Double, Double) -> Void)? {
        didSet { receiver.onSample = onSample }
    }

    private let appService = SMAppService.daemon(plistName: SensorServiceConstants.daemonPlistName)
    private let receiver = SensorClientReceiver()
    private var connection: NSXPCConnection?

    var authorization: HelperAuthorization {
        switch appService.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:
            // A fresh or reset Background Task Management database can report
            // `.notFound` before the first register() call even when the signed
            // service is correctly embedded. Treat that state as unregistered;
            // register() will surface an actionable error if the plist is invalid.
            return Self.hasBundledService() ? .notRegistered : .notFound
        @unknown default: return .notFound
        }
    }

    var registrationNeedsRefresh: Bool {
        guard authorization == .enabled else { return false }
        return UserDefaults.standard.string(forKey: Self.registeredServiceFingerprintKey)
            != Self.currentServiceFingerprint
    }

    static func hasBundledService(in bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let plistURL = bundleURL.appendingPathComponent(daemonPlistRelativePath)
        let helperURL = bundleURL.appendingPathComponent(helperRelativePath)
        return FileManager.default.isReadableFile(atPath: plistURL.path)
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    func register() throws {
        try appService.register()
        UserDefaults.standard.set(
            Self.currentServiceFingerprint,
            forKey: Self.registeredServiceFingerprintKey
        )
        UserDefaults.standard.removeObject(forKey: Self.legacyRegisteredBuildKey)
    }

    func unregister() throws {
        disconnect()
        try appService.unregister()
        Self.clearStoredRegistrationFingerprint()
    }

    func refreshRegistrationIfNeeded(completion: @escaping (Result<Void, Error>) -> Void) {
        guard registrationNeedsRefresh else {
            completion(.success(()))
            return
        }
        reinstallService(completion: completion)
    }

    /// Forces a full unregister → register cycle. A plain register() over an
    /// existing registration does not update Background Task Management's
    /// recorded code identity, so after the daemon binary changes launchd
    /// kills every new spawn with a launch-constraint violation until the
    /// registration is rebuilt from scratch.
    func reinstallService(completion: @escaping (Result<Void, Error>) -> Void) {
        disconnect()
        appService.unregister { [weak self] _ in
            // Unregister errors are ignored deliberately: the service may not
            // be registered at all, and register() below is the fix either way.
            guard let self else { return }
            Self.clearStoredRegistrationFingerprint()

            // Service Management can return EPERM when register() immediately
            // follows a daemon unregister. Apple DTS recommends returning to
            // the run loop; affected macOS releases also need a short delay
            // for Background Task Management to finish cleanup, and sometimes
            // a second attempt after a longer one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                do {
                    try self.register()
                    completion(.success(()))
                } catch {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self else { return }
                        do {
                            try self.register()
                            completion(.success(()))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Distinguishes the daemon answering with a failure from the daemon not
    /// answering at all — the latter usually means launchd cannot spawn it
    /// (for example after a launch-constraint violation) and the registration
    /// needs to be reinstalled.
    enum StartResult {
        case running(message: String)
        case daemonRefused(message: String)
        case unreachable(message: String)
    }

    private static let startReplyTimeout: TimeInterval = 8

    func start(
        sensitivity: Double,
        minimumTapInterval: Double,
        completion: @escaping (StartResult) -> Void
    ) {
        let connection = makeConnectionIfNeeded()

        // The reply, the proxy error handler, and the timeout race; only the
        // first outcome is delivered.
        let finishLock = NSLock()
        var finished = false
        let finish: (StartResult) -> Void = { result in
            let shouldDeliver = finishLock.withLock { () -> Bool in
                guard !finished else { return false }
                finished = true
                return true
            }
            if shouldDeliver { completion(result) }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.unreachable(message: error.localizedDescription))
        }) as? SensorDaemonProtocol else {
            finish(.unreachable(message: "Could not connect to the sensor service."))
            return
        }
        proxy.startMonitoring(
            sensitivity: sensitivity,
            minimumTapInterval: minimumTapInterval
        ) { success, message in
            finish(success ? .running(message: message) : .daemonRefused(message: message))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startReplyTimeout) {
            finish(.unreachable(message: "The sensor service did not respond."))
        }
    }

    func updateSensitivity(_ sensitivity: Double) {
        guard let proxy = connection?.remoteObjectProxy as? SensorDaemonProtocol else { return }
        proxy.setSensitivity(sensitivity)
    }

    func updateMinimumTapInterval(_ interval: Double) {
        guard let proxy = connection?.remoteObjectProxy as? SensorDaemonProtocol else { return }
        proxy.setMinimumTapInterval(interval)
    }

    func setTelemetryEnabled(_ enabled: Bool) {
        guard let proxy = connection?.remoteObjectProxy as? SensorDaemonProtocol else { return }
        proxy.setTelemetryEnabled(enabled)
    }

    func disconnect() {
        guard let connection else { return }
        if let proxy = connection.remoteObjectProxy as? SensorDaemonProtocol {
            proxy.stopMonitoring { }
        }
        connection.invalidate()
        self.connection = nil
    }

    private func makeConnectionIfNeeded() -> NSXPCConnection {
        if let connection { return connection }

        let connection = NSXPCConnection(
            machServiceName: SensorServiceConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SensorDaemonProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: SensorClientProtocol.self)
        connection.exportedObject = receiver
        connection.invalidationHandler = { [weak self] in
            self?.connection = nil
            self?.receiver.onStateChange?(false, "Sensor service disconnected.")
        }
        connection.interruptionHandler = { [weak receiver] in
            receiver?.onStateChange?(false, "Sensor service was interrupted.")
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    static func serviceFingerprint(in bundleURL: URL = Bundle.main.bundleURL) -> String? {
        let plistURL = bundleURL.appendingPathComponent(daemonPlistRelativePath)
        let helperURL = bundleURL.appendingPathComponent(helperRelativePath)
        guard
            let plistData = try? Data(contentsOf: plistURL, options: .mappedIfSafe),
            let helperData = try? Data(contentsOf: helperURL, options: .mappedIfSafe)
        else { return nil }

        var hasher = SHA256()
        hasher.update(data: plistData)
        hasher.update(data: helperData)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var currentServiceFingerprint: String {
        serviceFingerprint() ?? "unreadable-service-payload"
    }

    private static func clearStoredRegistrationFingerprint() {
        UserDefaults.standard.removeObject(forKey: registeredServiceFingerprintKey)
        UserDefaults.standard.removeObject(forKey: legacyRegisteredBuildKey)
    }
}
