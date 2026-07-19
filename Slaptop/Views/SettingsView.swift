// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    #if !APP_STORE
    @ObservedObject var updater: AppUpdater
    #endif
    let showSensorData: () -> Void

    init(model: AppModel, showSensorData: @escaping () -> Void = {}) {
        self.model = model
        #if !APP_STORE
        self.updater = model.updater
        #endif
        self.showSensorData = showSensorData
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            NativeVerticalScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    permissionsSection
                    detectionSection
                    calibrationSection
                    mappingSection
                    #if !APP_STORE
                    updatesSection
                    advancedSection
                    #endif
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                // Keep the first section heading clear of NSScrollView's
                // content-edge clipping at the initial zero offset.
                .padding(.top, 32)
            }
        }
        .frame(width: 680, height: 720)
        .onAppear(perform: model.refreshSystemState)
        .task {
            // Live-refresh permission state so granting Accessibility in
            // System Settings flips the row without reopening the window.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                model.refreshSystemState()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slaptop Settings")
                    .font(.title2.weight(.semibold))
                Text("Tap the display. Move through Spaces.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var permissionsSection: some View {
        SettingsSection(title: "Permissions", symbol: "checkmark.shield") {
            StatusRow(
                title: motionSensorTitle,
                value: motionSensorStatus,
                isReady: model.isInstalledInApplications && model.helperAuthorization == .enabled
            ) {
                #if APP_STORE
                EmptyView()
                #else
                HStack(spacing: 8) {
                    if !model.isInstalledInApplications || model.helperAuthorization != .enabled {
                        Button {
                            if model.isInstalledInApplications {
                                model.requestSensorPermission()
                            } else {
                                model.installInApplications()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if model.isInstallingApplication {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(model.isInstalledInApplications
                                    ? "Request Access"
                                    : (model.isInstallingApplication ? "Moving…" : "Move to Applications"))
                            }
                        }
                        .disabled(model.isInstallingApplication)
                    }
                    if model.isInstalledInApplications {
                        Button("Open Login Items") {
                            model.openBackgroundItemSettings()
                        }
                    }
                }
                .controlSize(.small)
                #endif
            }

            StatusRow(
                title: "Space switching (Accessibility)",
                value: model.isAccessibilityTrusted ? "Approved" : "Needs approval",
                isReady: model.isAccessibilityTrusted
            ) {
                if !model.isAccessibilityTrusted {
                    Button("Request Access") {
                        model.requestAccessibilityPermission()
                    }
                    .controlSize(.small)
                }
            }

            Text(motionSensorDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var detectionSection: some View {
        SettingsSection(title: "Tap detection", symbol: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(sensitivityLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $model.sensitivity,
                    in: TapSensitivity.minimum...TapSensitivity.maximum,
                    step: 0.01
                )
                    .accessibilityLabel("Tap sensitivity")
                Text("Lower values detect gentler taps. Raise this if typing or desk movement causes switches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Minimum time between taps")
                    Spacer()
                    Text(tapIntervalLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $model.minimumTapInterval,
                    in: TapTiming.minimumInterval...TapTiming.maximumInterval,
                    step: 0.01
                )
                .accessibilityLabel("Minimum time between detected taps")
                Text("Shorter intervals allow faster repeated Space changes. The fastest setting accepts up to three deliberate taps per second.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let magnitude = model.lastImpactMagnitude {
                LabeledContent("Last impact") {
                    Text(magnitude, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                }
            }

            HStack {
                Button {
                    showSensorData()
                } label: {
                    Label("Show Sensor Data", systemImage: "chart.xyaxis.line")
                }
                Spacer()
                Text(sensorStreamLabel)
                    .font(.caption)
                    .foregroundStyle(model.hasReceivedSensorSample ? Color.green : Color.secondary)
            }
        }
    }

    private var calibrationSection: some View {
        SettingsSection(title: "Tap location calibration", symbol: "scope") {
            Text(model.calibrationState.prompt)
                .font(.callout)
                .foregroundStyle(calibrationPromptColor)
                .fixedSize(horizontal: false, vertical: true)

            // Sample rejections ("wrong direction", "below threshold") were
            // previously only visible in the menu bar popover, making a
            // stalled calibration look unresponsive.
            if model.calibrationState.isCollecting,
               model.statusMessage != model.calibrationState.prompt {
                Label(model.statusMessage, systemImage: "exclamationmark.bubble")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Training accepts impacts of \(model.sensitivity.formatted(.number.precision(.fractionLength(2)))) g or stronger that rotate toward the selected location.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    model.beginCalibration(for: .left)
                } label: {
                    calibrationButtonLabel(for: .left, symbol: "hand.point.left")
                }
                .disabled(!model.isSensorRunning)
                Button {
                    model.beginCalibration(for: .right)
                } label: {
                    calibrationButtonLabel(for: .right, symbol: "hand.point.right")
                }
                .disabled(!model.isSensorRunning)
                Button {
                    model.beginCalibration(for: .top)
                } label: {
                    calibrationButtonLabel(for: .top, symbol: "hand.point.up")
                }
                .disabled(!model.isSensorRunning)
                Spacer()
                if model.isCalibrated {
                    Label("Calibrated", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }

            Button("Reset Calibration", role: .destructive) {
                model.resetCalibration()
            }
            .controlSize(.small)
        }
    }

    private var mappingSection: some View {
        SettingsSection(title: "Space mapping", symbol: "rectangle.3.group") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Tap direction", selection: $model.tapDirection) {
                    ForEach(TapDirectionPreference.allCases, id: \.self) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .layoutPriority(1)

                Button {
                    model.restoreDefaultKeyBindings()
                } label: {
                    Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(model.keyBindings == .standard)
                .help("Restore ⌃←, ⌃→, and ⌃↑")
            }

            Text(model.tapDirection == .natural
                ? "Natural: tapping a side moves to the Space on that side."
                : "Inverted: tapping a side pushes the desktop the other way.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            mappingRow(for: .left)
            mappingRow(for: .right)
            mappingRow(for: .top)
            Text("If you changed the system-wide Mission Control shortcuts, click a shortcut button and enter the matching key combination. Slaptop uses these bindings only to switch Spaces or open Mission Control; use Test to try each action without tapping the display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Space-action results (including permission errors) land in the
            // shared status message; without surfacing it here, a failing
            // Test button looks like a silent no-op.
            Label(model.statusMessage, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    #if !APP_STORE
    private var updatesSection: some View {
        SettingsSection(title: "Software updates", symbol: "arrow.down.circle") {
            HStack {
                Text("Version \(AppVersion.displayString(from: Bundle.main.infoDictionary ?? [:]))")
                Spacer()
                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .disabled(updaterIsBusy)
            }

            Picker("Check for updates", selection: $updater.frequency) {
                ForEach(UpdateCheckFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.label).tag(frequency)
                }
            }
            .pickerStyle(.segmented)

            Text(updater.statusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Updates come from the project's GitHub releases. Each downloaded update is verified against Slaptop's code signature before it is installed, and Slaptop relaunches automatically afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updaterIsBusy: Bool {
        switch updater.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var advancedSection: some View {
        SettingsSection(title: "Sensor service", symbol: "gearshape.2") {
            Text("The helper runs as root because macOS restricts direct access to the AppleSPU motion sensor. It only reads motion reports and has no network or file access logic.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Repair Sensor Service") {
                    model.repairSensorService()
                }
                Button("Remove Sensor Service", role: .destructive) {
                    model.removeSensorService()
                }
                .disabled(model.helperAuthorization == .notRegistered)
            }
            Text("Repair reinstalls the helper's background registration. Use it if Slaptop reports that it couldn't communicate with the helper — typically after an update, when macOS still expects the previous version's helper.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    private var motionSensorTitle: String {
        #if APP_STORE
        "Motion sensor (sandboxed)"
        #else
        "Motion sensor helper"
        #endif
    }

    private var motionSensorDescription: String {
        #if APP_STORE
        "Slaptop reads display taps in-process inside App Sandbox; it installs no privileged helper. Accessibility access lets Slaptop press the Mission Control and Spaces shortcuts configured under Space Mapping (defaults: ⌃←, ⌃→, and ⌃↑)."
        #else
        model.isInstalledInApplications
            ? "The motion sensor helper reads display taps. Accessibility access lets Slaptop press the Mission Control and Spaces shortcuts configured under Space Mapping (defaults: ⌃←, ⌃→, and ⌃↑)."
            : "App is not running from the /Applications folder. Move it there before requesting motion sensor access; Slaptop can copy itself and reopen the installed version automatically."
        #endif
    }

    private var motionSensorStatus: String {
        #if APP_STORE
        model.helperAuthorization.label
        #else
        model.isInstalledInApplications
            ? model.helperAuthorization.label
            : (model.isInstallingApplication ? "Moving…" : "Not in Applications")
        #endif
    }

    private var sensitivityLabel: String {
        switch model.sensitivity {
        case ..<0.13: return "Gentle"
        case 0.13..<0.29: return "Balanced"
        default: return "Firm"
        }
    }

    private var sensorStreamLabel: String {
        if !model.isSensorRunning { return "Sensor paused" }
        return model.hasReceivedSensorSample ? "Receiving live samples" : "Sensor connected"
    }

    private var tapIntervalLabel: String {
        let milliseconds = Int((model.minimumTapInterval * 1_000).rounded())
        let rate = TapTiming.tapsPerSecond(for: model.minimumTapInterval)
        return "\(milliseconds) ms · \(rate.formatted(.number.precision(.fractionLength(1)))) taps/s"
    }

    private var calibrationPromptColor: Color {
        switch model.calibrationState {
        case .collecting: return .accentColor
        case .learned: return .green
        case .idle: return .secondary
        }
    }

    private func mappingRow(for side: TapSide) -> some View {
        let action = side.action(for: model.tapDirection)
        return MappingRow(
            tap: tapLabel(for: side),
            action: action.label,
            symbol: action.symbol,
            keyBinding: Binding(
                get: { model.keyBinding(for: action) },
                set: { model.setKeyBinding($0, for: action) }
            )
        ) {
            model.testAction(action)
        }
    }

    private func tapLabel(for side: TapSide) -> String {
        switch side {
        case .left: return "Left-side tap"
        case .right: return "Right-side tap"
        case .top: return "Top-edge tap"
        }
    }

    private func calibrationButtonLabel(for side: TapSide, symbol: String) -> some View {
        Label(
            model.calibratedSides.contains(side) ? "Relearn \(side.label)" : "Learn \(side.label)",
            systemImage: model.calibratedSides.contains(side) ? "checkmark.circle.fill" : symbol
        )
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.headline)
            VStack(alignment: .leading, spacing: 13) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct StatusRow<Accessory: View>: View {
    let title: String
    let value: String
    let isReady: Bool
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer()
            accessory
        }
    }
}

private struct MappingRow: View {
    let tap: String
    let action: String
    let symbol: String
    @Binding var keyBinding: TapKeyBinding
    let testAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(tap, systemImage: symbol)
                .frame(minWidth: 145, alignment: .leading)
            Text(action)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer()
            ShortcutRecorderButton(
                binding: $keyBinding,
                actionLabel: action
            )
            .fixedSize()
            Button("Test", action: testAction)
                .controlSize(.small)
        }
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var binding: TapKeyBinding
    let actionLabel: String

    func makeNSView(context: Context) -> ShortcutRecordingButton {
        let button = ShortcutRecordingButton()
        let binding = _binding
        button.onBindingChange = { binding.wrappedValue = $0 }
        button.actionLabel = actionLabel
        button.binding = self.binding
        return button
    }

    func updateNSView(_ button: ShortcutRecordingButton, context: Context) {
        button.actionLabel = actionLabel
        if !button.isRecording {
            button.binding = binding
        }
    }
}

private final class ShortcutRecordingButton: NSButton {
    var binding = SpaceKeyBindings.standard.switchLeft {
        didSet { updatePresentation() }
    }
    var actionLabel = "Shortcut" {
        didSet { updatePresentation() }
    }
    var onBindingChange: ((TapKeyBinding) -> Void)?
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        focusRingType = .default
        updatePresentation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Type shortcut…"
        toolTip = "Type a shortcut, or press Escape to cancel"
        setAccessibilityValue("Waiting for a shortcut")
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.keyCode == 53, flags.isEmpty {
            finishRecording()
            return
        }

        var modifiers: KeyBindingModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let newBinding = TapKeyBinding(keyCode: event.keyCode, modifiers: modifiers)
        guard newBinding.isValid else {
            NSSound.beep()
            return
        }
        binding = newBinding
        onBindingChange?(newBinding)
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecording {
            isRecording = false
            updatePresentation()
        }
        return resigned
    }

    private func finishRecording() {
        isRecording = false
        updatePresentation()
        window?.makeFirstResponder(nil)
    }

    private func updatePresentation() {
        guard !isRecording else { return }
        title = binding.displayString
        toolTip = "Click to change the shortcut for \(actionLabel)"
        setAccessibilityLabel("Shortcut for \(actionLabel)")
        setAccessibilityValue(binding.accessibilityDescription)
        setAccessibilityHelp("Click, then type a new key combination")
        invalidateIntrinsicContentSize()
    }
}
