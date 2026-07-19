// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct FirstLaunchView: View {
    @ObservedObject var model: AppModel
    let completeSetup: () -> Void

    private var hasRequiredPermissions: Bool {
        #if APP_STORE
        model.helperAuthorization == .enabled
        #else
        model.isInstalledInApplications && model.helperAuthorization == .enabled
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            LaptopTapAnimationView()
                .frame(width: 500, height: 250)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.10), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Slaptop")
                        .font(.title2.bold())
                    Text(introduction)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SetupPermissionRow(
                    title: motionSensorTitle,
                    detail: motionSensorDetail,
                    status: motionSensorStatus,
                    isGranted: hasRequiredPermissions,
                    actionTitle: motionSensorActionTitle,
                    isWorking: motionSensorActionIsWorking,
                    requestPermission: motionSensorAction
                )

                SetupPermissionRow(
                    title: "Space switching (Accessibility)",
                    detail: "Presses the Mission Control and Spaces shortcuts (defaults: ⌃←, ⌃→, and ⌃↑).",
                    status: model.isAccessibilityTrusted ? "Approved" : "Needs approval",
                    isGranted: model.isAccessibilityTrusted,
                    actionTitle: "Request Permission",
                    isWorking: false,
                    requestPermission: model.requestAccessibilityPermission
                )

                Divider()

                Button(action: completeSetup) {
                    Label("Travel Spaces", systemImage: "rectangle.3.group.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasRequiredPermissions)

                if !hasRequiredPermissions {
                    Text(missingSensorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 22)
        }
        .frame(width: 500, height: 620, alignment: .top)
        .onAppear(perform: model.refreshSystemState)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                model.refreshSystemState()
            }
        }
    }

    private var introduction: String {
        #if APP_STORE
        "Slaptop reads display taps inside App Sandbox so they can travel through Mission Control Spaces."
        #else
        model.isInstalledInApplications
            ? "Approve the motion sensor helper so display taps can travel through Mission Control Spaces."
            : "App is not running from the /Applications folder. Move it there before setting up permissions."
        #endif
    }

    private var motionSensorTitle: String {
        #if APP_STORE
        "Motion sensor (sandboxed)"
        #else
        "Motion sensor helper"
        #endif
    }

    private var motionSensorDetail: String {
        #if APP_STORE
        "Reads display taps in-process; no privileged helper is installed."
        #else
        model.isInstalledInApplications
            ? "Reads display taps from AppleSPU."
            : "The helper requires Slaptop to run from /Applications."
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

    private var motionSensorActionTitle: String {
        #if APP_STORE
        "Request Permission"
        #else
        model.isInstalledInApplications ? "Request Permission" : "Move to Applications"
        #endif
    }

    private var motionSensorActionIsWorking: Bool {
        #if APP_STORE
        false
        #else
        !model.isInstalledInApplications && model.isInstallingApplication
        #endif
    }

    private var motionSensorAction: () -> Void {
        #if APP_STORE
        model.requestSensorPermission
        #else
        model.isInstalledInApplications
            ? model.requestSensorPermission
            : model.installInApplications
        #endif
    }

    private var missingSensorMessage: String {
        #if APP_STORE
        "Travel Spaces requires a compatible built-in AppleSPU motion sensor."
        #else
        model.isInstalledInApplications
            ? "Travel Spaces becomes available after the motion sensor helper is approved."
            : "App is not running from the /Applications folder. Slaptop can move itself there and reopen the installed copy automatically."
        #endif
    }
}

private struct SetupPermissionRow: View {
    let title: String
    let detail: String
    let status: String
    let isGranted: Bool
    let actionTitle: String
    let isWorking: Bool
    let requestPermission: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.shield.fill" : "shield")
                .font(.title2)
                .foregroundStyle(isGranted ? .green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isGranted ? .green : .orange)
            }

            Spacer(minLength: 12)

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Permission granted")
            } else {
                Button(action: requestPermission) {
                    HStack(spacing: 5) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isWorking ? "Moving…" : actionTitle)
                    }
                }
                .controlSize(.small)
                .disabled(isWorking)
            }
        }
        .padding(13)
        .background(
            .quaternary.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
