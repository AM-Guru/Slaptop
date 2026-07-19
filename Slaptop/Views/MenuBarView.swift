// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Combine
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSensorLoggingEnabled: Bool
    @Published private(set) var statusMessage: String
    @Published private(set) var lastTapSide: TapSide?
    @Published private(set) var lastTapTriggeredAction: Bool
    @Published private(set) var tapDirection: TapDirectionPreference
    #if !APP_STORE
    @Published private(set) var updateStatus: String?
    #endif

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        isEnabled = model.isEnabled
        isSensorLoggingEnabled = model.isSensorLoggingEnabled
        statusMessage = model.statusMessage
        lastTapSide = model.lastTapSide
        lastTapTriggeredAction = model.lastTapTriggeredAction
        tapDirection = model.tapDirection

        model.$isEnabled.removeDuplicates().assign(to: &$isEnabled)
        model.$isSensorLoggingEnabled.removeDuplicates().assign(to: &$isSensorLoggingEnabled)
        model.$statusMessage.removeDuplicates().assign(to: &$statusMessage)
        model.$lastTapSide.removeDuplicates().assign(to: &$lastTapSide)
        model.$lastTapTriggeredAction.removeDuplicates().assign(to: &$lastTapTriggeredAction)
        model.$tapDirection.removeDuplicates().assign(to: &$tapDirection)
        #if !APP_STORE
        model.updater.$phase
            .map(Self.updateStatusText(for:))
            .removeDuplicates()
            .assign(to: &$updateStatus)
        #endif
    }

    func toggleEnabled() {
        model.toggleEnabled()
    }

    #if !APP_STORE
    func checkForUpdates() {
        model.updater.checkForUpdates()
    }

    private static func updateStatusText(for phase: AppUpdater.Phase) -> String? {
        switch phase {
        case .idle:
            return nil
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Slaptop is up to date."
        case let .availableButNotInstallable(tag):
            return "Update \(tag) is available. Install Slaptop in /Applications to update automatically."
        case let .downloading(tag):
            return "Downloading Slaptop \(tag)…"
        case let .installing(tag):
            return "Installing Slaptop \(tag)… Slaptop will relaunch."
        case let .failed(message):
            return message
        }
    }
    #endif
}

struct MenuBarView: View {
    @StateObject private var viewModel: MenuBarViewModel
    let showSettings: () -> Void
    let showAbout: () -> Void
    let quit: () -> Void

    init(
        model: AppModel,
        showSettings: @escaping () -> Void,
        showAbout: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: MenuBarViewModel(model: model))
        self.showSettings = showSettings
        self.showAbout = showAbout
        self.quit = quit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.tint.opacity(0.14))
                    Image(systemName: viewModel.isEnabled ? "hand.tap.fill" : "hand.tap")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Slaptop")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(activityColor)
                            .frame(width: 7, height: 7)
                        Text(activityLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Button(action: viewModel.toggleEnabled) {
                Label(
                    viewModel.isEnabled ? "Disable Slaptop" : "Enable Slaptop",
                    systemImage: viewModel.isEnabled ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let side = viewModel.lastTapSide {
                Label(lastTapLabel(for: side), systemImage: lastTapSymbol(for: side))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Divider()

            VStack(spacing: 2) {
                MenuBarRow(title: "Settings…", symbol: "slider.horizontal.3", action: showSettings)
                #if !APP_STORE
                MenuBarRow(
                    title: "Check for Updates…",
                    symbol: "arrow.down.circle",
                    action: viewModel.checkForUpdates
                )
                #endif
                MenuBarRow(title: "About Slaptop…", symbol: "info.circle", action: showAbout)
                MenuBarRow(title: "Quit Slaptop", symbol: "power", action: quit)
            }

            #if !APP_STORE
            if let updateStatus = viewModel.updateStatus {
                Text(updateStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
        .padding(16)
        .frame(width: 300)
    }

    private var activityLabel: String {
        if viewModel.isEnabled { return "Listening" }
        if viewModel.isSensorLoggingEnabled { return "Sensor logging only" }
        return "Paused"
    }

    private var activityColor: Color {
        viewModel.isEnabled || viewModel.isSensorLoggingEnabled ? .green : .secondary
    }

    private func lastTapLabel(for side: TapSide) -> String {
        if viewModel.lastTapTriggeredAction {
            return "Last: \(side.label) tap → \(side.action(for: viewModel.tapDirection).label)"
        }
        return "Last sensor tap: \(side.label) — no action"
    }

    private func lastTapSymbol(for side: TapSide) -> String {
        viewModel.lastTapTriggeredAction
            ? side.action(for: viewModel.tapDirection).symbol
            : "waveform.path.ecg"
    }
}

private struct MenuBarRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }
}
