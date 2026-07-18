// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct FirstLaunchView: View {
    @ObservedObject var model: AppModel
    let completeSetup: () -> Void

    private var hasRequiredPermissions: Bool {
        model.helperAuthorization == .enabled
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
                    Text("Approve the motion sensor helper so display taps can travel through Mission Control Spaces.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SetupPermissionRow(
                    title: "Motion sensor helper",
                    detail: "Reads display taps from AppleSPU.",
                    status: model.helperAuthorization.label,
                    isGranted: model.helperAuthorization == .enabled,
                    requestPermission: model.requestSensorPermission
                )

                SetupPermissionRow(
                    title: "Space switching (Accessibility)",
                    detail: "Presses the Mission Control shortcuts (⌃← ⌃→) to switch Spaces.",
                    status: model.isAccessibilityTrusted ? "Approved" : "Needs approval",
                    isGranted: model.isAccessibilityTrusted,
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
                    Text("Travel Spaces becomes available after the motion sensor helper is approved.")
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
}

private struct SetupPermissionRow: View {
    let title: String
    let detail: String
    let status: String
    let isGranted: Bool
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
                Button("Request Permission", action: requestPermission)
                    .controlSize(.small)
            }
        }
        .padding(13)
        .background(
            .quaternary.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
