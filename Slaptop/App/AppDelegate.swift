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

    override init() {
        let defaults = UserDefaults.standard
        let shouldPresentSetup = FirstLaunchPreference.shouldPresent(defaults: defaults)
        shouldPresentFirstLaunchSetup = shouldPresentSetup
        model = AppModel(defaults: defaults, automaticallyEnable: !shouldPresentSetup)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.target = self
        item.button?.action = #selector(toggleStatusPopover(_:))
        statusItem = item
        updateStatusItem()
        // Scheduled here rather than in AppModel's initializer so unit tests
        // constructing models never start network activity.
        model.updater.startAutomaticChecks()

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
        } else {
            // Give every About presentation its own animation timeline so it
            // always opens at rest instead of resuming midway through a tap.
            aboutWindowController?.window?.contentViewController =
                NSHostingController(rootView: AboutView())
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
            sensorDataWindowController?.window?.delegate = self
        }
        present(sensorDataWindowController)
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            window === sensorDataWindowController?.window
        else { return }
        model.setSensorDataPresentationActive(false)
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
        return NSWindowController(window: window)
    }

    private func present(_ controller: NSWindowController?) {
        guard let window = controller?.window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
