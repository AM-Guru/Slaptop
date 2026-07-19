// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    let showSensorData: () -> Void

    init(model: AppModel, showSensorData: @escaping () -> Void = {}) {
        self.model = model
        self.updater = model.updater
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
                    updatesSection
                    advancedSection
                }
                .padding(24)
            }
        }
        .frame(width: 520, height: 610)
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
                title: "Motion sensor helper",
                value: model.helperAuthorization.label,
                isReady: model.helperAuthorization == .enabled
            ) {
                HStack(spacing: 8) {
                    if model.helperAuthorization != .enabled {
                        Button("Request Access") {
                            model.requestSensorPermission()
                        }
                    }
                    Button("Open Login Items") {
                        model.openBackgroundItemSettings()
                    }
                }
                .controlSize(.small)
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

            Text("The motion sensor helper reads display taps. Accessibility access lets Slaptop press the Mission Control shortcuts (⌃← ⌃→) that switch Spaces.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            // Sample rejections ("wrong direction", "below threshold") were
            // previously only visible in the menu bar popover, making a
            // stalled calibration look unresponsive.
            if model.calibrationState.isCollecting,
               model.statusMessage != model.calibrationState.prompt {
                Label(model.statusMessage, systemImage: "exclamationmark.bubble")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Text("Training accepts impacts of \(model.sensitivity.formatted(.number.precision(.fractionLength(2)))) g or stronger that rotate toward the selected location.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
            Picker("Tap direction", selection: $model.tapDirection) {
                ForEach(TapDirectionPreference.allCases, id: \.self) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            Text(model.tapDirection == .natural
                ? "Natural: tapping a side moves to the Space on that side."
                : "Inverted: tapping a side pushes the desktop the other way.")
                .font(.caption)
                .foregroundStyle(.secondary)

            mappingRow(for: .left)
            mappingRow(for: .right)
            mappingRow(for: .top)
            Text("Space switches press the standard Mission Control shortcuts (⌃← ⌃→) on your behalf. Test each action with the button on its row.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Space-action results (including permission errors) land in the
            // shared status message; without surfacing it here, a failing
            // Test button looks like a silent no-op.
            Label(model.statusMessage, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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

            Text("Updates come from the project's GitHub releases. Each downloaded update is verified against Slaptop's code signature before it is installed, and Slaptop relaunches automatically afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        }
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
            symbol: action.symbol
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
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

private struct MappingRow: View {
    let tap: String
    let action: String
    let symbol: String
    let testAction: () -> Void

    var body: some View {
        HStack {
            Label(tap, systemImage: symbol)
            Text(action)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Test", action: testAction)
                .controlSize(.small)
        }
    }
}
