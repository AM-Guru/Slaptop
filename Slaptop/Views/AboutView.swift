// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            LaptopTapAnimationView()
                .frame(width: 500, height: 275)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.10), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("Slaptop")
                        .font(.largeTitle.bold())
                    Text("Slaptop for macOS by Kalani Helekunihi")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Based on the 2005 tool")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("Tap left to switch one Space right. Tap right to switch one Space left. Tap the top edge to launch Mission Control.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 410)

                Divider()

                VStack(spacing: 7) {
                    Text("A little history")
                        .font(.headline)
                    Text("“As it turns out, hitting a laptop with a hard drive kills your data. Thankfully, SSDs no longer have that problem.”")
                        .font(.callout)
                        .italic()
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }

                Text("Version \(AppVersion.displayString)  •  Apple silicon")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 26)
        }
        .frame(width: 500, height: 570, alignment: .top)
    }
}
