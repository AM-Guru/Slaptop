// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private enum PresentedWindow {
        case settings
        case about
    }

    private static let statusSymbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: 13,
        weight: .regular
    )

    let model: AppModel
    private let shouldPresentFirstLaunchSetup: Bool

    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var modelObservation: AnyCancellable?
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var sensorDataWindowController: NSWindowController?
    private var firstLaunchWindowController: NSWindowController?
    #if DEBUG
    private var negativeGestureCapture: NegativeGestureCapture?
    #endif

    override init() {
        let defaults = UserDefaults.standard
        let shouldPresentSetup = FirstLaunchPreference.shouldPresent(defaults: defaults)
        shouldPresentFirstLaunchSetup = shouldPresentSetup
        model = AppModel(defaults: defaults, automaticallyEnable: !shouldPresentSetup)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        startNegativeGestureCaptureIfRequested()
        #endif

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.target = self
        item.button?.action = #selector(toggleStatusPopover(_:))
        statusItem = item
        updateStatusItem()
        // Scheduled here rather than in AppModel's initializer so unit tests
        // constructing models never start network activity.
        #if !APP_STORE && !LOCAL_DEV
        model.updater.startAutomaticChecks()
        #endif

        modelObservation = Publishers.CombineLatest(model.$isEnabled, model.$isSensorLoggingEnabled)
            .removeDuplicates { previous, current in
                previous.0 == current.0 && previous.1 == current.1
            }
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }

        if shouldPresentFirstLaunchSetup {
            presentFirstLaunchSetup()
        } else if ProcessInfo.processInfo.arguments.contains("--show-sensor-data") {
            // Local release-build diagnostics can open the live graph without
            // using UI automation or an Xcode-built app bundle.
            presentSensorData()
        }
    }

    #if DEBUG
    /// Development-only sensor capture used to turn physical false positives
    /// into reproducible negative classifier and detector fixtures. It runs as
    /// a second signed XPC client, so the installed app and its calibration do
    /// not need to be replaced or modified.
    private func startNegativeGestureCaptureIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let flagIndex = arguments.firstIndex(of: "--capture-negative-gestures"),
            arguments.indices.contains(flagIndex + 1)
        else { return }

        do {
            let capture = try NegativeGestureCapture(
                outputURL: URL(fileURLWithPath: arguments[flagIndex + 1]),
                defaults: .standard
            )
            negativeGestureCapture = capture
            capture.start()
        } catch {
            print("SLAPTOP_NEGATIVE_CAPTURE_ERROR \(error.localizedDescription)")
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        statusPopover?.close()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func updateStatusItem() {
        let enabled = model.isEnabled
        let image = NSImage(
            systemSymbolName: enabled ? "hand.tap.fill" : "hand.tap",
            accessibilityDescription: enabled ? "Slaptop enabled" : "Slaptop paused"
        )?.withSymbolConfiguration(Self.statusSymbolConfiguration)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = enabled
            ? "Slaptop — Listening"
            : (model.isSensorLoggingEnabled ? "Slaptop — Sensor logging only" : "Slaptop — Paused")
    }

    @objc private func toggleStatusPopover(_ sender: NSStatusBarButton) {
        if statusPopover?.isShown == true {
            statusPopover?.performClose(sender)
            return
        }

        model.refreshSystemState()
        let view = MenuBarView(
            model: model,
            showSettings: { [weak self] in
                self?.closePopoverThenPresent(.settings)
            },
            showAbout: { [weak self] in
                self?.closePopoverThenPresent(.about)
            },
            quit: {
                NSApplication.shared.terminate(nil)
            }
        )
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        statusPopover = popover
        sender.highlight(true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        guard
            let closedPopover = notification.object as? NSPopover,
            closedPopover === statusPopover
        else { return }
        closedPopover.contentViewController = nil
        statusPopover = nil
    }

    private func closePopoverThenPresent(_ destination: PresentedWindow) {
        statusPopover?.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            switch destination {
            case .settings:
                self?.presentSettings()
            case .about:
                self?.presentAbout()
            }
        }
    }

    private func presentSettings() {
        if settingsWindowController == nil {
            let view = SettingsView(model: model) { [weak self] in
                self?.presentSensorData()
            }
            settingsWindowController = makeWindow(
                title: "Slaptop Settings",
                size: NSSize(width: 680, height: 720),
                rootView: view
            )
        }
        present(settingsWindowController)
    }

    private func presentAbout() {
        if aboutWindowController == nil {
            aboutWindowController = makeWindow(
                title: "About Slaptop",
                size: NSSize(width: 500, height: 570),
                rootView: AboutView()
            )
        }
        present(aboutWindowController)
    }

    private func presentSensorData() {
        model.setSensorDataPresentationActive(true)
        if sensorDataWindowController == nil {
            sensorDataWindowController = makeWindow(
                title: "Slaptop Sensor Data",
                size: NSSize(width: 760, height: 720),
                rootView: SensorDataView(model: model)
            )
        }
        present(sensorDataWindowController)
    }

    /// Closed windows must not linger with live SwiftUI content: AppKit keeps
    /// servicing an ordered-out window's tracking areas every display cycle,
    /// and current macOS builds regenerate the pointer image on each pass,
    /// which pegs the main thread while the app is otherwise idle. Detach the
    /// hosting view and drop the controller; presenters rebuild on demand.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if window === sensorDataWindowController?.window {
            model.setSensorDataPresentationActive(false)
            sensorDataWindowController = nil
        } else if window === settingsWindowController?.window {
            settingsWindowController = nil
        } else if window === aboutWindowController?.window {
            aboutWindowController = nil
        } else if window === firstLaunchWindowController?.window {
            firstLaunchWindowController = nil
        } else {
            return
        }
        window.contentViewController = nil
    }

    private func presentFirstLaunchSetup() {
        guard firstLaunchWindowController == nil else {
            present(firstLaunchWindowController)
            return
        }

        let view = FirstLaunchView(model: model) { [weak self] in
            self?.completeFirstLaunchSetup()
        }
        firstLaunchWindowController = makeWindow(
            title: "Welcome to Slaptop",
            size: NSSize(width: 500, height: 620),
            rootView: view
        )
        present(firstLaunchWindowController)
    }

    private func completeFirstLaunchSetup() {
        FirstLaunchPreference.markCompleted()
        firstLaunchWindowController?.close()
        firstLaunchWindowController = nil

        if ActivationPreference.shouldEnableOnLaunch() {
            model.enable(userInitiated: false)
        }
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        rootView: Content
    ) -> NSWindowController {
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.center()
        window.delegate = self
        return NSWindowController(window: window)
    }

    private func present(_ controller: NSWindowController?) {
        guard let window = controller?.window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

#if DEBUG
private final class NegativeGestureCapture {
    private let outputURL: URL
    private let fileHandle: FileHandle
    private let service = SensorServiceController()
    private let classifier: TapClassifier
    private let sensitivity: Double
    private let writeQueue = DispatchQueue(label: "guru.am.slaptop.negative-gesture-capture")

    init(outputURL: URL, defaults: UserDefaults) throws {
        self.outputURL = outputURL
        classifier = TapClassifier(defaults: defaults)
        sensitivity = TapSensitivity.clamp(
            defaults.object(forKey: "sensor.sensitivity") as? Double
                ?? TapSensitivity.defaultThreshold
        )

        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        fileHandle = try FileHandle(forWritingTo: outputURL)

        service.onSample = { [weak self] acceleration, gyroscope, magnitude, timestamp in
            self?.append([
                "kind": "sample",
                "timestamp": timestamp,
                "acceleration": acceleration.map(\.doubleValue),
                "gyroscope": gyroscope.map(\.doubleValue),
                "magnitude": magnitude,
            ])
        }
        service.onImpact = { [weak self] numbers, magnitude in
            self?.recordImpact(numbers, magnitude: magnitude)
        }
    }

    deinit {
        service.disconnect()
        try? fileHandle.close()
    }

    func start() {
        append([
            "kind": "capture-start",
            "timestamp": ProcessInfo.processInfo.systemUptime,
            "sensitivity": sensitivity,
            "minimumTapInterval": TapTiming.minimumInterval,
            "calibratedSides": classifier.calibratedSides.map(\.rawValue).sorted(),
        ])
        service.start(
            sensitivity: sensitivity,
            minimumTapInterval: TapTiming.minimumInterval
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .running:
                self.service.setTelemetryEnabled(true)
                print("SLAPTOP_NEGATIVE_CAPTURE_READY \(self.outputURL.path)")
            case let .daemonRefused(message), let .unreachable(message):
                print("SLAPTOP_NEGATIVE_CAPTURE_ERROR \(message)")
            }
        }
    }

    private func recordImpact(_ numbers: [NSNumber], magnitude: Double) {
        guard let features = ImpactFeatures(numbers) else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let classification = classifier.classify(features)?.rawValue ?? "none"
        append([
            "kind": "impact",
            "timestamp": timestamp,
            "features": features.values,
            "magnitude": magnitude,
            "classification": classification,
        ], synchronize: true)
        let featureText = features.values.map { String(format: "%.5f", $0) }.joined(separator: ",")
        print(
            String(
                format: "SLAPTOP_NEGATIVE_IMPACT %.6f magnitude=%.5f classification=%@ features=[%@]",
                timestamp,
                magnitude,
                classification,
                featureText
            )
        )
    }

    private func append(_ object: [String: Any], synchronize: Bool = false) {
        writeQueue.async { [fileHandle] in
            guard
                JSONSerialization.isValidJSONObject(object),
                var data = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            else { return }
            data.append(0x0A)
            do {
                try fileHandle.write(contentsOf: data)
                if synchronize {
                    try fileHandle.synchronize()
                }
            } catch {
                print("SLAPTOP_NEGATIVE_CAPTURE_ERROR \(error.localizedDescription)")
            }
        }
    }
}
#endif
