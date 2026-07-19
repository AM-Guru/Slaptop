// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum CalibrationState: Equatable {
        case idle
        case collecting(side: TapSide, count: Int)
        case learned(side: TapSide)

        var isCollecting: Bool {
            if case .collecting = self { return true }
            return false
        }

        var prompt: String {
            switch self {
            case .idle:
                return "Calibrate all three locations to enable top-tap detection."
            case let .collecting(side, count):
                return "Tap the \(side.calibrationTarget) of the display — \(3 - count) remaining"
            case let .learned(side):
                return "Learned the \(side.calibrationTarget). Choose another location or relearn it."
            }
        }
    }

    enum CustomGestureTrainingState: Equatable {
        case idle
        case recording(repetition: Int, eventCount: Int)
        case ready(
            repetition: Int,
            completed: Int,
            expectedEventCount: Int,
            message: String?
        )
        case learned(name: String)

        var isActive: Bool {
            switch self {
            case .recording, .ready: return true
            case .idle, .learned: return false
            }
        }

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var prompt: String {
            switch self {
            case .idle:
                return "Create an action, then perform the same tap or knock pattern three times."
            case let .recording(repetition, eventCount):
                if eventCount == 0 {
                    return "Sample \(repetition) of 3: perform the pattern now."
                }
                return "Sample \(repetition) of 3: recorded \(eventCount) impact\(eventCount == 1 ? "" : "s"). Pause briefly when finished."
            case let .ready(repetition, completed, expectedEventCount, message):
                if let message { return message }
                return "Sample \(completed) saved with \(expectedEventCount) impact\(expectedEventCount == 1 ? "" : "s"). Record sample \(repetition) the same way."
            case let .learned(name):
                return "“\(name)” is learned and ready to use."
            }
        }
    }

    private enum MonitoringRequest {
        case spaceSwitching
        case sensorLogging
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var isSensorLoggingEnabled = false
    @Published private(set) var isSensorRunning = false
    @Published private(set) var helperAuthorization: HelperAuthorization = .notRegistered
    @Published private(set) var isAccessibilityTrusted = false
    #if !APP_STORE
    @Published private(set) var isInstallingApplication = false
    #endif
    @Published private(set) var statusMessage = "Ready to set up"
    @Published private(set) var lastTapSide: TapSide?
    @Published private(set) var lastImpactMagnitude: Double?
    @Published private(set) var lastDetectedTapDate: Date?
    @Published private(set) var lastTapTriggeredAction = false
    @Published private(set) var sensorSamples: [LiveSensorSample] = []
    @Published private(set) var hasReceivedSensorSample = false
    @Published private(set) var calibrationState: CalibrationState = .idle
    @Published private(set) var isCalibrated = false
    @Published private(set) var calibratedSides: Set<TapSide> = []
    @Published private(set) var customGesturePatterns: [CustomGesturePattern]
    @Published private(set) var customGestureTrainingState: CustomGestureTrainingState = .idle
    @Published var sensitivity: Double {
        didSet {
            defaults.set(sensitivity, forKey: Self.sensitivityKey)
            sensorService.updateSensitivity(activeSensorSensitivity)
        }
    }
    @Published var minimumTapInterval: Double {
        didSet {
            let value = TapTiming.clamp(minimumTapInterval)
            defaults.set(value, forKey: Self.minimumTapIntervalKey)
            sensorService.updateMinimumTapInterval(activeSensorMinimumTapInterval)
        }
    }
    @Published var tapDirection: TapDirectionPreference {
        didSet {
            defaults.set(tapDirection.rawValue, forKey: TapDirectionPreference.key)
        }
    }
    @Published private(set) var keyBindings: SpaceKeyBindings

    var isInstalledInApplications: Bool {
        #if APP_STORE
        true
        #else
        MissionControlController.isInstalledApplication
        #endif
    }

    var sensorDetectionThreshold: Double {
        activeSensorSensitivity
    }

    var sensorGyroscopeDetectionThreshold: Double {
        TapSensitivity.gyroscopeThreshold(for: activeSensorSensitivity)
    }

    private static let sensitivityKey = "sensor.sensitivity"
    private static let sensitivityModelVersionKey = "sensor.sensitivityModelVersion"
    private static let minimumTapIntervalKey = "sensor.minimumTapInterval"
    private static let maximumSensorSamples = 300
    private static let sensorChartUpdateInterval: TimeInterval = 1.0 / 8.0
    private static let calibrationArmingDelay = 0.35
    private static let customGestureArmingDelay = 0.35
    private static let customGestureRecordingSilence: TimeInterval = 1.35
    #if !APP_STORE
    let updater = AppUpdater()
    #endif
    private let sensorService = SensorServiceController()
    private let defaults: UserDefaults
    private let classifier: TapClassifier
    private let missionControlController = MissionControlController()
    private var calibrationSamples: [ImpactFeatures] = []
    private var calibrationArmedAt: TimeInterval = 0
    private struct CustomGestureDraft {
        let id: UUID
        let name: String
        let action: CustomGestureAction
    }
    private struct PendingCustomGestureImpact {
        let features: ImpactFeatures
        let timestamp: TimeInterval
    }
    private var customGestureDraft: CustomGestureDraft?
    private var customGestureTrainingSamples: [CustomGestureSample] = []
    private var customGestureCurrentEvents: [CustomGestureEvent] = []
    private var customGestureLastEventAt: TimeInterval?
    private var customGestureArmedAt: TimeInterval = 0
    private var customGestureRecordingWorkItem: DispatchWorkItem?
    private var pendingCustomGestureImpacts: [PendingCustomGestureImpact] = []
    private var pendingCompletedCustomGesture: CustomGesturePattern?
    private var pendingCustomGestureWorkItem: DispatchWorkItem?
    private var pendingCustomGestureSequenceID: UUID?
    private var lastStandardImpactAt: TimeInterval = -.infinity
    private var nextSensorSampleID: UInt64 = 0
    private var isRefreshingSensorService = false
    /// One automatic registration repair per start attempt; cleared on success.
    private var hasAttemptedServiceRepair = false
    private var rawSensorSamples: [LiveSensorSample] = []
    private var isSensorDataPresentationActive = false
    private var lastSensorChartUpdateAt: TimeInterval = -.infinity
    private var pendingSensorChartUpdate: DispatchWorkItem?

    private var activeSensorSensitivity: Double {
        sensitivity
    }

    private var activeSensorMinimumTapInterval: Double {
        customGesturePatterns.isEmpty && !customGestureTrainingState.isActive
            ? minimumTapInterval
            : TapTiming.minimumInterval
    }

    init(defaults: UserDefaults = .standard, automaticallyEnable: Bool = true) {
        self.defaults = defaults
        #if !DEBUG
        // Motion-feature diagnostics were historically persisted for support.
        // Release builds neither retain new samples nor keep the legacy ring.
        defaults.removeObject(forKey: Self.recentImpactDiagnosticsKey)
        #endif
        classifier = TapClassifier(defaults: defaults)
        sensitivity = Self.loadSensitivity(defaults: defaults)
        let savedTapInterval = defaults.object(forKey: Self.minimumTapIntervalKey) as? Double
        minimumTapInterval = TapTiming.clamp(savedTapInterval ?? TapTiming.defaultInterval)
        tapDirection = TapDirectionPreference(
            rawValue: defaults.string(forKey: TapDirectionPreference.key) ?? ""
        ) ?? .natural
        keyBindings = SpaceKeyBindings.load(from: defaults)
        customGesturePatterns = CustomGestureStore.load(from: defaults)
        isCalibrated = classifier.isCalibrated
        calibratedSides = classifier.calibratedSides

        sensorService.onImpact = { [weak self] numbers, magnitude in
            DispatchQueue.main.async {
                self?.handleImpact(numbers, magnitude: magnitude)
            }
        }
        sensorService.onSample = { [weak self] acceleration, gyroscope, impactMagnitude, timestamp in
            DispatchQueue.main.async {
                self?.handleSensorSample(
                    acceleration: acceleration,
                    gyroscope: gyroscope,
                    impactMagnitude: impactMagnitude,
                    timestamp: timestamp
                )
            }
        }
        sensorService.onStateChange = { [weak self] running, message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSensorRunning = running
                // While a registration refresh/repair is under way the
                // connection tear-down produces transient disconnection
                // messages; the repair flow owns the status line then.
                if !self.isRefreshingSensorService {
                    self.statusMessage = message
                }
                if !running {
                    if !self.isRefreshingSensorService {
                        self.isEnabled = false
                        self.isSensorLoggingEnabled = false
                    }
                    self.calibrationState = .idle
                    self.calibrationSamples.removeAll()
                    self.calibrationArmedAt = 0
                    self.cancelCustomGestureTraining()
                    self.clearPendingCustomGestureRecognition()
                }
            }
        }
        refreshSystemState()

        if automaticallyEnable, ActivationPreference.shouldEnableOnLaunch(defaults: defaults) {
            DispatchQueue.main.async { [weak self] in
                self?.enable(userInitiated: false)
            }
        }
    }

    func refreshSystemState() {
        helperAuthorization = sensorService.authorization
        isAccessibilityTrusted = MissionControlController.isAccessibilityTrusted

        if SensorMonitoringPolicy.shouldMonitor(
            isSlaptopEnabled: isEnabled,
            isSensorLoggingEnabled: isSensorLoggingEnabled
        ), helperAuthorization != .enabled {
            isEnabled = false
            isSensorLoggingEnabled = false
            isSensorRunning = false
        }
    }

    func toggleEnabled() {
        isEnabled ? disable(userInitiated: true) : enable(userInitiated: true)
    }

    func enable(userInitiated: Bool = true) {
        if userInitiated {
            ActivationPreference.setEnabled(true, defaults: defaults)
        }

        guard isInstalledInApplications else {
            statusMessage = "Install Slaptop in /Applications before requesting permissions or testing."
            return
        }

        refreshSystemState()

        activateSensorService(for: .spaceSwitching)
    }

    func disable(userInitiated: Bool = true) {
        if userInitiated {
            ActivationPreference.setEnabled(false, defaults: defaults)
        }
        isEnabled = false
        calibrationState = .idle
        calibrationSamples.removeAll()
        calibrationArmedAt = 0
        cancelCustomGestureTraining()
        clearPendingCustomGestureRecognition()
        if SensorMonitoringPolicy.shouldMonitor(
            isSlaptopEnabled: isEnabled,
            isSensorLoggingEnabled: isSensorLoggingEnabled
        ) {
            statusMessage = "Sensor logging only. Space switching is off."
        } else {
            stopSensorMonitoring(message: "Paused")
        }
    }

    func setSensorLoggingEnabled(_ enabled: Bool) {
        guard enabled != isSensorLoggingEnabled else { return }

        if !enabled {
            isSensorLoggingEnabled = false
            if SensorMonitoringPolicy.shouldMonitor(
                isSlaptopEnabled: isEnabled,
                isSensorLoggingEnabled: isSensorLoggingEnabled
            ) {
                statusMessage = "Independent logging is off. Slaptop remains enabled."
            } else {
                calibrationState = .idle
                calibrationSamples.removeAll()
                calibrationArmedAt = 0
                cancelCustomGestureTraining()
                clearPendingCustomGestureRecognition()
                stopSensorMonitoring(message: "Sensor logging paused.")
            }
            return
        }

        guard isInstalledInApplications else {
            statusMessage = "Install Slaptop in /Applications before logging sensor data."
            return
        }

        refreshSystemState()
        isSensorLoggingEnabled = true
        activateSensorService(for: .sensorLogging)
    }

    func requestSensorPermission() {
        guard isInstalledInApplications else {
            installInApplications()
            return
        }

        refreshSystemState()
        switch helperAuthorization {
        case .notRegistered:
            do {
                try sensorService.register()
                refreshSystemState()
                if helperAuthorization == .requiresApproval {
                    sensorService.openApprovalSettings()
                    statusMessage = "Approve Slaptop under Allow in the Background, then return here."
                } else if helperAuthorization == .enabled {
                    statusMessage = "Motion sensor permission granted."
                } else {
                    statusMessage = "Sensor helper registered. Waiting for macOS approval status."
                }
            } catch {
                statusMessage = "Sensor service registration failed: \(error.localizedDescription)"
            }
        case .requiresApproval:
            sensorService.openApprovalSettings()
            statusMessage = "Approve Slaptop under Allow in the Background, then return here."
        case .enabled:
            statusMessage = "Motion sensor permission granted."
        case .notFound:
            statusMessage = unavailableSensorMessage
        }
    }

    func installInApplications() {
        #if !APP_STORE
        guard !isInstalledInApplications, !isInstallingApplication else { return }
        isInstallingApplication = true
        statusMessage = "Moving Slaptop to Applications…"
        let sourceURL = Bundle.main.bundleURL

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try AppInstallationManager.installCurrentApplication(from: sourceURL)
                }
            }.value

            guard let self else { return }
            self.isInstallingApplication = false
            switch result {
            case let .success(outcome):
                self.statusMessage = outcome == .installed
                    ? "Slaptop was moved to Applications. Reopening the installed copy…"
                    : "Slaptop is already in Applications. Opening the installed copy…"
                do {
                    try AppInstallationManager.relaunchInstalledApplication()
                } catch {
                    self.statusMessage = error.localizedDescription
                    MissionControlController.showInstallationFolders()
                }
            case let .failure(error):
                self.statusMessage = "\(error.localizedDescription) Move it manually, then reopen Slaptop from Applications."
                MissionControlController.showInstallationFolders()
            }
        }
        #endif
    }

    func showInstallationFolders() {
        #if !APP_STORE
        MissionControlController.showInstallationFolders()
        statusMessage = "Drag Slaptop into Applications, quit this copy, then reopen Slaptop from Applications before requesting sensor access."
        #endif
    }

    func openBackgroundItemSettings() {
        sensorService.openApprovalSettings()
    }

    func requestAccessibilityPermission() {
        MissionControlController.requestAccessibilityAccess()
        refreshSystemState()
        statusMessage = isAccessibilityTrusted
            ? "Accessibility access granted."
            : "Enable Slaptop under Privacy & Security → Accessibility, then return here."
    }

    /// Manual escape hatch for the "Couldn't communicate with the helper
    /// application" state: Background Task Management can keep a previous
    /// build's daemon identity, making launchd kill every new spawn until the
    /// registration is rebuilt.
    func repairSensorService() {
        isRefreshingSensorService = true
        isEnabled = false
        isSensorLoggingEnabled = false
        isSensorRunning = false
        statusMessage = "Repairing the sensor service registration…"
        sensorService.reinstallService { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingSensorService = false
                self.refreshSystemState()
                switch result {
                case .success:
                    if self.helperAuthorization == .requiresApproval {
                        self.sensorService.openApprovalSettings()
                        self.statusMessage = "Re-approve Slaptop under Allow in the Background, then enable Slaptop again."
                    } else {
                        self.statusMessage = "Sensor service reinstalled. Enable Slaptop to reconnect."
                    }
                case .failure(let error):
                    self.sensorService.openApprovalSettings()
                    self.statusMessage = "Repair failed: \(error.localizedDescription). In the Login Items window that just opened, switch Slaptop off and back on under Allow in the Background, then try again. Restarting your Mac also clears this."
                }
            }
        }
    }

    func removeSensorService() {
        do {
            try sensorService.unregister()
            ActivationPreference.setEnabled(false, defaults: defaults)
            isEnabled = false
            isSensorLoggingEnabled = false
            isSensorRunning = false
            refreshSystemState()
            statusMessage = "Sensor service removed."
        } catch {
            statusMessage = "Could not remove sensor service: \(error.localizedDescription)"
        }
    }

    func beginCalibration(for side: TapSide) {
        guard isSensorRunning else {
            statusMessage = "Enable Slaptop or independent sensor logging before calibrating."
            return
        }
        cancelCustomGestureTraining()
        clearPendingCustomGestureRecognition()
        calibrationSamples.removeAll()
        calibrationState = .collecting(side: side, count: 0)
        calibrationArmedAt = ProcessInfo.processInfo.systemUptime + Self.calibrationArmingDelay
        sensorService.updateSensitivity(sensitivity)
        lastTapSide = nil
        lastDetectedTapDate = nil
        lastTapTriggeredAction = false
        statusMessage = calibrationState.prompt
    }

    func resetCalibration() {
        classifier.reset()
        isCalibrated = false
        calibratedSides = []
        calibrationState = .idle
        calibrationSamples.removeAll()
        calibrationArmedAt = 0
        sensorService.updateSensitivity(sensitivity)
        statusMessage = "Calibration reset."
    }

    func clearSensorHistory() {
        pendingSensorChartUpdate?.cancel()
        pendingSensorChartUpdate = nil
        rawSensorSamples.removeAll(keepingCapacity: true)
        sensorSamples.removeAll(keepingCapacity: true)
        hasReceivedSensorSample = false
        nextSensorSampleID = 0
        lastSensorChartUpdateAt = -.infinity
    }

    func setSensorDataPresentationActive(_ active: Bool) {
        guard active != isSensorDataPresentationActive else { return }
        isSensorDataPresentationActive = active
        pendingSensorChartUpdate?.cancel()
        pendingSensorChartUpdate = nil
        sensorService.setTelemetryEnabled(active)

        if active {
            publishSensorChartSnapshot()
        }
    }

    func testAction(_ action: SpaceAction) {
        let binding = keyBinding(for: action)
        statusMessage = "Performing \(binding.displayString) for \(action.label)…"
        missionControlController.perform(binding) { [weak self] result in
            self?.finishSpaceAction(
                result,
                successMessage: "\(action.label) · \(binding.displayString)"
            )
        }
    }

    func keyBinding(for action: SpaceAction) -> TapKeyBinding {
        keyBindings.binding(for: action)
    }

    func setKeyBinding(_ binding: TapKeyBinding, for action: SpaceAction) {
        guard binding.isValid else { return }
        keyBindings.set(binding, for: action)
        keyBindings.save(to: defaults)
        statusMessage = "\(action.label) now uses \(binding.displayString)."
    }

    func restoreDefaultKeyBindings() {
        keyBindings = .standard
        defaults.removeObject(forKey: SpaceKeyBindings.defaultsKey)
        statusMessage = "Restored the default Mission Control and Spaces shortcuts."
    }

    @discardableResult
    func beginCustomGestureTraining(
        id: UUID = UUID(),
        name: String,
        action: CustomGestureAction
    ) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, action.isValid else {
            statusMessage = "Give the pattern a name and a valid action before learning it."
            return false
        }
        guard isSensorRunning else {
            statusMessage = "Enable Slaptop or independent sensor logging before learning a pattern."
            return false
        }

        cancelCustomGestureTraining()
        clearPendingCustomGestureRecognition()
        calibrationState = .idle
        calibrationSamples.removeAll()
        calibrationArmedAt = 0
        customGestureDraft = CustomGestureDraft(
            id: id,
            name: trimmedName,
            action: action
        )
        customGestureTrainingSamples.removeAll(keepingCapacity: true)
        startCustomGestureRepetition(1)
        sensorService.updateMinimumTapInterval(activeSensorMinimumTapInterval)
        statusMessage = customGestureTrainingState.prompt
        return true
    }

    func recordNextCustomGestureSample() {
        guard case let .ready(repetition, _, _, _) = customGestureTrainingState,
              customGestureDraft != nil
        else { return }
        startCustomGestureRepetition(repetition)
        statusMessage = customGestureTrainingState.prompt
    }

    func cancelCustomGestureTraining() {
        customGestureRecordingWorkItem?.cancel()
        customGestureRecordingWorkItem = nil
        customGestureDraft = nil
        customGestureTrainingSamples.removeAll(keepingCapacity: true)
        customGestureCurrentEvents.removeAll(keepingCapacity: true)
        customGestureLastEventAt = nil
        customGestureArmedAt = 0
        customGestureTrainingState = .idle
        sensorService.updateMinimumTapInterval(activeSensorMinimumTapInterval)
    }

    func updateCustomGesture(
        id: UUID,
        name: String,
        action: CustomGestureAction
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, action.isValid,
              let index = customGesturePatterns.firstIndex(where: { $0.id == id })
        else { return }
        customGesturePatterns[index].name = trimmedName
        customGesturePatterns[index].action = action
        CustomGestureStore.save(customGesturePatterns, to: defaults)
        statusMessage = "Updated \(trimmedName)."
    }

    func deleteCustomGesture(id: UUID) {
        guard let index = customGesturePatterns.firstIndex(where: { $0.id == id }) else {
            return
        }
        let name = customGesturePatterns[index].name
        customGesturePatterns.remove(at: index)
        CustomGestureStore.save(customGesturePatterns, to: defaults)
        clearPendingCustomGestureRecognition()
        sensorService.updateMinimumTapInterval(activeSensorMinimumTapInterval)
        statusMessage = "Deleted \(name)."
    }

    func testCustomGestureAction(_ action: CustomGestureAction, name: String) {
        let successMessage = "\(name) → \(action.summary)"
        statusMessage = "Testing \(successMessage)…"
        missionControlController.perform(action) { [weak self] result in
            self?.finishSpaceAction(result, successMessage: successMessage)
        }
    }

    private func activateSensorService(for request: MonitoringRequest) {
        if isSensorRunning {
            markMonitoringRequestActive(request)
            statusMessage = activeMessage(for: request)
            return
        }

        switch helperAuthorization {
        case .notRegistered:
            do {
                try sensorService.register()
                refreshSystemState()
                if helperAuthorization == .requiresApproval {
                    cancelMonitoringRequest(request)
                    sensorService.openApprovalSettings()
                    statusMessage = approvalMessage(for: request)
                } else {
                    beginMonitoring(for: request)
                }
            } catch {
                cancelMonitoringRequest(request)
                statusMessage = "Sensor service registration failed: \(error.localizedDescription)"
            }
        case .requiresApproval:
            cancelMonitoringRequest(request)
            sensorService.openApprovalSettings()
            statusMessage = approvalMessage(for: request)
        case .notFound:
            cancelMonitoringRequest(request)
            statusMessage = unavailableSensorMessage
        case .enabled:
            if sensorService.registrationNeedsRefresh {
                isRefreshingSensorService = true
                statusMessage = "Updating the sensor service…"
                sensorService.refreshRegistrationIfNeeded { [weak self] result in
                    DispatchQueue.main.async {
                        self?.finishSensorServiceRefresh(result, request: request)
                    }
                }
            } else {
                beginMonitoring(for: request)
            }
        }
    }

    private func beginMonitoring(for request: MonitoringRequest) {
        statusMessage = "Connecting to the motion sensor…"
        sensorService.start(
            sensitivity: activeSensorSensitivity,
            minimumTapInterval: activeSensorMinimumTapInterval
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.finishSensorStart(result, request: request)
            }
        }
    }

    private func finishSensorStart(
        _ result: SensorServiceController.StartResult,
        request: MonitoringRequest
    ) {
        switch result {
        case .running:
            hasAttemptedServiceRepair = false
            isSensorRunning = true
            markMonitoringRequestActive(request)
            sensorService.setTelemetryEnabled(isSensorDataPresentationActive)
            statusMessage = activeMessage(for: request)
        case .daemonRefused(let message):
            isSensorRunning = false
            cancelMonitoringRequest(request)
            statusMessage = message
        case .unreachable:
            isSensorRunning = false
            guard !hasAttemptedServiceRepair else {
                // Reinstalling the registration did not help: on some macOS
                // releases Background Task Management keeps the original
                // approval's launch constraint until the user toggles the
                // item or restarts, so hand the user that exact instruction
                // with the right Settings pane already open.
                cancelMonitoringRequest(request)
                sensorService.openApprovalSettings()
                statusMessage = "macOS is still blocking the updated sensor helper. In the Login Items window that just opened, switch Slaptop off and back on under Allow in the Background, then enable Slaptop again. Restarting your Mac also clears this."
                return
            }
            // An unreachable daemon usually means launchd is killing its
            // spawns because Background Task Management still records a
            // previous build's code identity. Reinstalling the registration
            // rebuilds that record.
            hasAttemptedServiceRepair = true
            statusMessage = "The sensor service is not responding. Repairing its registration…"
            sensorService.reinstallService { [weak self] repairResult in
                DispatchQueue.main.async {
                    self?.finishSensorServiceRepair(repairResult, request: request)
                }
            }
        }
    }

    private func finishSensorServiceRepair(
        _ result: Result<Void, Error>,
        request: MonitoringRequest
    ) {
        refreshSystemState()
        switch result {
        case .failure(let error):
            cancelMonitoringRequest(request)
            statusMessage = "Could not repair the sensor service: \(error.localizedDescription)"
        case .success:
            if helperAuthorization == .requiresApproval {
                cancelMonitoringRequest(request)
                sensorService.openApprovalSettings()
                statusMessage = approvalMessage(for: request, isReapproval: true)
            } else {
                beginMonitoring(for: request)
            }
        }
    }

    private func finishSensorServiceRefresh(
        _ result: Result<Void, Error>,
        request: MonitoringRequest
    ) {
        isRefreshingSensorService = false
        refreshSystemState()
        switch result {
        case .failure(let error):
            cancelMonitoringRequest(request)
            statusMessage = "Could not update the sensor service: \(error.localizedDescription)"
        case .success:
            if helperAuthorization == .requiresApproval {
                cancelMonitoringRequest(request)
                sensorService.openApprovalSettings()
                statusMessage = approvalMessage(for: request, isReapproval: true)
            } else if helperAuthorization == .enabled {
                if request == .sensorLogging, !isSensorLoggingEnabled {
                    statusMessage = "Sensor logging paused."
                } else {
                    beginMonitoring(for: request)
                }
            } else {
                cancelMonitoringRequest(request)
                statusMessage = "The sensor service update did not finish. Try again to retry."
            }
        }
    }

    private func markMonitoringRequestActive(_ request: MonitoringRequest) {
        switch request {
        case .spaceSwitching:
            isEnabled = true
        case .sensorLogging:
            isSensorLoggingEnabled = true
        }
    }

    private func cancelMonitoringRequest(_ request: MonitoringRequest) {
        switch request {
        case .spaceSwitching:
            isEnabled = false
        case .sensorLogging:
            isSensorLoggingEnabled = false
        }
    }

    private func activeMessage(for request: MonitoringRequest) -> String {
        switch request {
        case .spaceSwitching:
            return "Listening for display taps."
        case .sensorLogging:
            return isEnabled
                ? "Sensor logging will continue when Slaptop is disabled."
                : "Sensor logging only. Space switching is off."
        }
    }

    private func approvalMessage(
        for request: MonitoringRequest,
        isReapproval: Bool = false
    ) -> String {
        let verb = isReapproval ? "Re-approve" : "Approve"
        switch request {
        case .spaceSwitching:
            return "\(verb) Slaptop under Allow in the Background, then enable again."
        case .sensorLogging:
            return "\(verb) Slaptop under Allow in the Background, then turn sensor logging on again."
        }
    }

    private var unavailableSensorMessage: String {
        #if APP_STORE
        "No compatible built-in AppleSPU motion sensor is available. Slaptop requires an Apple Silicon Mac with an integrated display."
        #else
        "The bundled sensor helper is missing. Rebuild and move Slaptop to Applications."
        #endif
    }

    private func stopSensorMonitoring(message: String) {
        sensorService.disconnect()
        isSensorRunning = false
        statusMessage = message
    }

    private func handleImpact(_ numbers: [NSNumber], magnitude: Double) {
        guard let features = ImpactFeatures(numbers) else { return }
        logImpact(features, magnitude: magnitude)
        lastImpactMagnitude = magnitude
        lastDetectedTapDate = Date()
        lastTapTriggeredAction = false

        if customGestureTrainingState.isActive {
            if customGestureTrainingState.isRecording {
                recordCustomGestureTrainingImpact(
                    features,
                    timestamp: ProcessInfo.processInfo.systemUptime
                )
            }
            return
        }

        if case let .collecting(side, count) = calibrationState {
            guard ProcessInfo.processInfo.systemUptime >= calibrationArmedAt else {
                lastDetectedTapDate = nil
                return
            }
            if let rejection = CalibrationSampleValidator.rejection(
                for: features,
                magnitude: magnitude,
                threshold: sensitivity,
                learning: side,
                opposingSideYaw: opposingSideYaw(for: side)
            ) {
                switch rejection {
                case .belowThreshold:
                    statusMessage = String(
                        format: "Ignored %.2f g impact. Calibration requires at least %.2f g or a firm rotation.",
                        magnitude,
                        sensitivity
                    )
                case .wrongDirection:
                    statusMessage = "Ignored motion from the wrong direction. Tap the \(side.calibrationTarget)."
                }
                appendImpactDiagnostic("rejected (\(rejection)) while learning \(side.rawValue)")
                return
            }
            appendImpactDiagnostic("accepted sample \(count + 1)/3 for \(side.rawValue)")
            calibrationSamples.append(features)
            let newCount = count + 1
            if newCount >= 3 {
                classifier.save(samples: calibrationSamples, for: side)
                calibrationSamples.removeAll()
                calibrationState = .learned(side: side)
                calibrationArmedAt = 0
                sensorService.updateSensitivity(sensitivity)
                isCalibrated = classifier.isCalibrated
                calibratedSides = classifier.calibratedSides
                statusMessage = "Learned the \(side.calibrationTarget)."
            } else {
                calibrationState = .collecting(side: side, count: newCount)
                statusMessage = calibrationState.prompt
            }
            return
        }

        let impact = PendingCustomGestureImpact(
            features: features,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        if customGesturePatterns.isEmpty {
            handleStandardImpact(impact)
        } else {
            processCustomGestureImpact(impact)
        }
    }

    private func startCustomGestureRepetition(_ repetition: Int) {
        customGestureRecordingWorkItem?.cancel()
        customGestureRecordingWorkItem = nil
        customGestureCurrentEvents.removeAll(keepingCapacity: true)
        customGestureLastEventAt = nil
        customGestureArmedAt = ProcessInfo.processInfo.systemUptime
            + Self.customGestureArmingDelay
        customGestureTrainingState = .recording(repetition: repetition, eventCount: 0)
    }

    private func recordCustomGestureTrainingImpact(
        _ features: ImpactFeatures,
        timestamp: TimeInterval
    ) {
        guard case let .recording(repetition, _) = customGestureTrainingState,
              timestamp >= customGestureArmedAt
        else { return }

        let interval = customGestureLastEventAt.map { timestamp - $0 } ?? 0
        customGestureCurrentEvents.append(
            CustomGestureEvent(
                features: features.values,
                intervalSincePrevious: interval
            )
        )
        customGestureLastEventAt = timestamp
        customGestureTrainingState = .recording(
            repetition: repetition,
            eventCount: customGestureCurrentEvents.count
        )
        statusMessage = customGestureTrainingState.prompt

        customGestureRecordingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishCustomGestureRepetition()
        }
        customGestureRecordingWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.customGestureRecordingSilence,
            execute: workItem
        )
    }

    private func finishCustomGestureRepetition() {
        guard case let .recording(repetition, _) = customGestureTrainingState,
              let draft = customGestureDraft,
              !customGestureCurrentEvents.isEmpty
        else { return }

        customGestureRecordingWorkItem = nil
        let candidate = CustomGestureSample(events: customGestureCurrentEvents)
        customGestureCurrentEvents.removeAll(keepingCapacity: true)
        customGestureLastEventAt = nil

        if let expectedCount = customGestureTrainingSamples.first?.events.count,
           candidate.events.count != expectedCount {
            customGestureTrainingState = .ready(
                repetition: repetition,
                completed: customGestureTrainingSamples.count,
                expectedEventCount: expectedCount,
                message: "That sample had \(candidate.events.count) impacts; the learned pattern has \(expectedCount). Record sample \(repetition) again."
            )
            statusMessage = customGestureTrainingState.prompt
            return
        }

        if !customGestureTrainingSamples.isEmpty,
           !CustomGestureMatcher.samplesAreConsistent(
                candidate,
                with: customGestureTrainingSamples
           ) {
            let expectedCount = customGestureTrainingSamples[0].events.count
            customGestureTrainingState = .ready(
                repetition: repetition,
                completed: customGestureTrainingSamples.count,
                expectedEventCount: expectedCount,
                message: "That performance didn't resemble the first sample closely enough. Record sample \(repetition) again."
            )
            statusMessage = customGestureTrainingState.prompt
            return
        }

        customGestureTrainingSamples.append(candidate)
        guard customGestureTrainingSamples.count
                >= CustomGestureMatcher.requiredTrainingSampleCount
        else {
            customGestureTrainingState = .ready(
                repetition: customGestureTrainingSamples.count + 1,
                completed: customGestureTrainingSamples.count,
                expectedEventCount: candidate.events.count,
                message: nil
            )
            statusMessage = customGestureTrainingState.prompt
            return
        }

        let learnedPattern = CustomGesturePattern(
            id: draft.id,
            name: draft.name,
            action: draft.action,
            samples: customGestureTrainingSamples
        )
        guard learnedPattern.isValid else {
            cancelCustomGestureTraining()
            statusMessage = "The pattern couldn't be saved. Please try learning it again."
            return
        }

        if let index = customGesturePatterns.firstIndex(where: { $0.id == draft.id }) {
            customGesturePatterns[index] = learnedPattern
        } else {
            customGesturePatterns.append(learnedPattern)
        }
        CustomGestureStore.save(customGesturePatterns, to: defaults)
        customGestureDraft = nil
        customGestureTrainingSamples.removeAll(keepingCapacity: true)
        customGestureArmedAt = 0
        customGestureTrainingState = .learned(name: learnedPattern.name)
        sensorService.updateMinimumTapInterval(activeSensorMinimumTapInterval)
        statusMessage = customGestureTrainingState.prompt
    }

    private func processCustomGestureImpact(_ impact: PendingCustomGestureImpact) {
        let candidateImpacts = pendingCustomGestureImpacts + [impact]
        let candidateEvents = customGestureEvents(from: candidateImpacts)
        let fullMatch = CustomGestureMatcher.bestFullMatch(
            for: candidateEvents,
            among: customGesturePatterns
        )
        let matchingPrefixes = CustomGestureMatcher.matchingPrefixes(
            for: candidateEvents,
            among: customGesturePatterns
        )
        if !matchingPrefixes.isEmpty {
            pendingCustomGestureImpacts = candidateImpacts
            if let fullMatch {
                // Prefer a longer code when one pattern is the prefix of
                // another, but retain the completed shorter pattern as the
                // timeout fallback.
                pendingCompletedCustomGesture = fullMatch
            }
            schedulePendingCustomGestureTimeout(for: matchingPrefixes)
            statusMessage = "Recognized the start of a custom pattern…"
            return
        }

        if let fullMatch {
            clearPendingCustomGestureRecognition()
            performCustomGesture(fullMatch)
            return
        }

        if !pendingCustomGestureImpacts.isEmpty {
            let allImpacts = candidateImpacts
            let completedPattern = pendingCompletedCustomGesture
            clearPendingCustomGestureRecognition()
            if let completedPattern {
                performCustomGesture(completedPattern)
                allImpacts
                    .dropFirst(completedPattern.eventCount)
                    .forEach(processCustomGestureImpact)
            } else {
                handleStandardImpact(allImpacts[0])
                allImpacts.dropFirst().forEach(processCustomGestureImpact)
            }
            return
        }

        handleStandardImpact(impact)
    }

    private func schedulePendingCustomGestureTimeout(
        for matchingPatterns: [CustomGesturePattern]
    ) {
        pendingCustomGestureWorkItem?.cancel()
        let sequenceID = UUID()
        pendingCustomGestureSequenceID = sequenceID
        let timeout = CustomGestureMatcher.continuationTimeout(
            afterEventCount: pendingCustomGestureImpacts.count,
            for: matchingPatterns
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingCustomGestureSequenceID == sequenceID else { return }
            self.flushPendingCustomGestureImpacts()
        }
        pendingCustomGestureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func flushPendingCustomGestureImpacts() {
        let impacts = pendingCustomGestureImpacts
        let completedPattern = pendingCompletedCustomGesture
        clearPendingCustomGestureRecognition()
        if let completedPattern {
            performCustomGesture(completedPattern)
            impacts
                .dropFirst(completedPattern.eventCount)
                .forEach(processCustomGestureImpact)
        } else {
            guard let firstImpact = impacts.first else { return }
            handleStandardImpact(firstImpact)
            impacts.dropFirst().forEach(processCustomGestureImpact)
        }
    }

    private func clearPendingCustomGestureRecognition() {
        pendingCustomGestureWorkItem?.cancel()
        pendingCustomGestureWorkItem = nil
        pendingCustomGestureSequenceID = nil
        pendingCustomGestureImpacts.removeAll(keepingCapacity: true)
        pendingCompletedCustomGesture = nil
    }

    private func customGestureEvents(
        from impacts: [PendingCustomGestureImpact]
    ) -> [CustomGestureEvent] {
        impacts.enumerated().map { index, impact in
            CustomGestureEvent(
                features: impact.features.values,
                intervalSincePrevious: index == 0
                    ? 0
                    : impact.timestamp - impacts[index - 1].timestamp
            )
        }
    }

    private func performCustomGesture(_ pattern: CustomGesturePattern) {
        appendImpactDiagnostic("matched custom pattern \(pattern.id.uuidString)")
        lastTapSide = nil
        guard SensorMonitoringPolicy.shouldPerformSpaceAction(isSlaptopEnabled: isEnabled) else {
            statusMessage = "Detected \(pattern.name). Logging only; no action sent."
            return
        }

        lastTapTriggeredAction = true
        let successMessage = "\(pattern.name) → \(pattern.action.summary)"
        statusMessage = "\(successMessage)…"
        missionControlController.perform(pattern.action) { [weak self] result in
            self?.finishSpaceAction(result, successMessage: successMessage)
        }
    }

    private func handleStandardImpact(_ impact: PendingCustomGestureImpact) {
        guard let side = classifier.classify(impact.features) else {
            lastTapSide = nil
            statusMessage = "Detected an impact that doesn't match a calibrated tap location."
            appendImpactDiagnostic("classified as no-match")
            return
        }
        appendImpactDiagnostic("classified as \(side.rawValue)")
        lastTapSide = side
        guard SensorMonitoringPolicy.shouldPerformSpaceAction(isSlaptopEnabled: isEnabled) else {
            statusMessage = "Detected \(side.label.lowercased()) tap. Logging only; no action sent."
            return
        }

        // Custom patterns keep the sensor at its fastest reporting interval
        // so their rhythm is observable. Preserve the user's ordinary tap
        // debounce here when that interval is slower.
        guard impact.timestamp - lastStandardImpactAt >= minimumTapInterval else {
            statusMessage = "Ignored a repeated \(side.label.lowercased()) tap during the minimum interval."
            return
        }
        lastStandardImpactAt = impact.timestamp
        lastTapTriggeredAction = true
        let action = side.action(for: tapDirection)
        let binding = keyBinding(for: action)
        let successMessage = "\(side.label) tap → \(action.label) · \(binding.displayString)"
        statusMessage = "\(successMessage)…"
        missionControlController.perform(binding) { [weak self] result in
            self?.finishSpaceAction(result, successMessage: successMessage)
        }
    }

    private static let recentImpactDiagnosticsKey = "diagnostics.recentImpacts"
    private static let maximumImpactDiagnostics = 60

    /// Debug-only diagnostic lines help inspect calibration and classification
    /// without retaining timestamped motion features in production builds.
    private func logImpact(_ features: ImpactFeatures, magnitude: Double) {
        #if DEBUG
        let values = features.values
        let context: String
        if case let .collecting(side, _) = calibrationState {
            context = "learning \(side.rawValue)"
        } else {
            context = "monitoring"
        }
        appendImpactDiagnostic(
            String(
                format: "[%@] accel=(%.3f, %.3f, %.3f) gyro=(%.2f, %.2f, %.2f) magnitude=%.3f",
                context, values[0], values[1], values[2], values[3], values[4], values[5], magnitude
            )
        )
        #endif
    }

    private func appendImpactDiagnostic(_ line: String) {
        #if DEBUG
        let stamped = "\(Date().formatted(.iso8601)) \(line)"
        var recent = defaults.stringArray(forKey: Self.recentImpactDiagnosticsKey) ?? []
        recent.append(stamped)
        if recent.count > Self.maximumImpactDiagnostics {
            recent.removeFirst(recent.count - Self.maximumImpactDiagnostics)
        }
        defaults.set(recent, forKey: Self.recentImpactDiagnosticsKey)
        #endif
    }

    /// The learned yaw of the opposite side, used to keep left and right
    /// calibration rotationally distinguishable without hardcoding a
    /// hardware-dependent sign convention.
    private func opposingSideYaw(for side: TapSide) -> Double? {
        switch side {
        case .left: return classifier.rightCentroid?.values[5]
        case .right: return classifier.leftCentroid?.values[5]
        case .top: return nil
        }
    }

    private func finishSpaceAction(
        _ result: Result<Void, Error>,
        successMessage: String
    ) {
        switch result {
        case .success:
            statusMessage = successMessage
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    private func handleSensorSample(
        acceleration: [NSNumber],
        gyroscope: [NSNumber],
        impactMagnitude: Double,
        timestamp: Double
    ) {
        guard
            timestamp.isFinite,
            impactMagnitude.isFinite,
            let acceleration = SensorAxes(acceleration),
            let gyroscope = SensorAxes(gyroscope)
        else { return }

        nextSensorSampleID &+= 1
        rawSensorSamples.append(
            LiveSensorSample(
                id: nextSensorSampleID,
                timestamp: timestamp,
                acceleration: acceleration,
                gyroscope: gyroscope,
                impactMagnitude: impactMagnitude
            )
        )
        if rawSensorSamples.count > Self.maximumSensorSamples {
            rawSensorSamples.removeFirst(rawSensorSamples.count - Self.maximumSensorSamples)
        }
        if !hasReceivedSensorSample {
            hasReceivedSensorSample = true
        }
        scheduleSensorChartUpdate()
    }

    private func scheduleSensorChartUpdate() {
        guard isSensorDataPresentationActive, pendingSensorChartUpdate == nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(
            0,
            Self.sensorChartUpdateInterval - (now - lastSensorChartUpdateAt)
        )
        if delay == 0 {
            publishSensorChartSnapshot()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.publishSensorChartSnapshot()
        }
        pendingSensorChartUpdate = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func publishSensorChartSnapshot() {
        pendingSensorChartUpdate = nil
        guard isSensorDataPresentationActive else { return }
        lastSensorChartUpdateAt = ProcessInfo.processInfo.systemUptime
        sensorSamples = rawSensorSamples
    }

    private static func loadSensitivity(defaults: UserDefaults = .standard) -> Double {
        let savedValue = defaults.object(forKey: sensitivityKey) as? Double
        let savedVersion = defaults.integer(forKey: sensitivityModelVersionKey)

        // Values saved by earlier sensitivity models are reset to the firm
        // default once; the setting stays user-adjustable afterwards.
        let value: Double
        if savedVersion < TapSensitivity.modelVersion {
            value = TapSensitivity.defaultThreshold
        } else {
            value = savedValue ?? TapSensitivity.defaultThreshold
        }

        let clamped = TapSensitivity.clamp(value)
        defaults.set(clamped, forKey: sensitivityKey)
        defaults.set(TapSensitivity.modelVersion, forKey: sensitivityModelVersionKey)
        return clamped
    }
}
