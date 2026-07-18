// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct SensorDataView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    loggingPanel
                    detectorPanel
                    vectorChart(
                        title: "Accelerometer",
                        unit: "g",
                        current: model.sensorSamples.last?.acceleration,
                        domain: SensorChartScale.acceleration,
                        value: { $0.acceleration }
                    )
                    vectorChart(
                        title: "Gyroscope",
                        unit: "°/s",
                        current: model.sensorSamples.last?.gyroscope,
                        domain: SensorChartScale.gyroscope,
                        value: { $0.gyroscope }
                    )
                }
                .padding(22)
            }
        }
        .frame(width: 760, height: 720)
        .transaction { transaction in
            // Live telemetry should replace the previous frame, not animate
            // hundreds of individual graph values into their new positions.
            transaction.animation = nil
        }
        .onAppear {
            model.setSensorDataPresentationActive(true)
        }
        .onDisappear {
            model.setSensorDataPresentationActive(false)
        }
    }

    private var loggingPanel: some View {
        SensorPanel {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Independent sensor logging")
                        .font(.headline)
                    Text("Stream live IMU measurements without performing Space actions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Log while Slaptop is off", isOn: sensorLoggingBinding)
                    .toggleStyle(.switch)
            }

            if model.isSensorLoggingEnabled && !model.isEnabled {
                Label("Logging only — Space switching is off", systemImage: "waveform.path.ecg")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            } else if model.isSensorLoggingEnabled {
                Text("Logging will continue if Slaptop is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This switch is session-only. Slaptop still receives the sensor data it needs while Space switching is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sensorLoggingBinding: Binding<Bool> {
        Binding(
            get: { model.isSensorLoggingEnabled },
            set: { model.setSensorLoggingEnabled($0) }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slaptop Sensor Data")
                    .font(.title2.weight(.semibold))
                Text("A rolling 12-second view of the motion sensor")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(streamStatus.title, systemImage: streamStatus.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(streamStatus.color)
            if let sampleRate {
                Text("\(sampleRate, format: .number.precision(.fractionLength(0))) Hz")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Clear") {
                model.clearSensorHistory()
            }
            .disabled(model.sensorSamples.isEmpty)
        }
        .padding(22)
    }

    private var detectorPanel: some View {
        SensorPanel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tap detector")
                        .font(.headline)
                    if let date = model.lastDetectedTapDate {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(detectedTapDescription)
                            Text(date, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    } else {
                        Text("No tap has crossed the detection threshold yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Threshold \(model.sensorDetectionThreshold, format: .number.precision(.fractionLength(2))) g")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            SensorPlotCanvas(
                samples: model.sensorSamples,
                domain: SensorChartScale.impact,
                series: [
                    SensorPlotSeries(color: .accentColor) { $0.impactMagnitude },
                ],
                thresholds: [model.sensorDetectionThreshold]
            )
            .frame(height: 115)

            Text(model.calibrationState.isCollecting
                ? "Calibration capture is active. A tap counts when acceleration crosses the orange line. Side-like rotation is ignored while learning Top."
                : "A tap counts when acceleration crosses the orange line. Adjust Sensitivity in Settings if deliberate taps stay below it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func vectorChart(
        title: String,
        unit: String,
        current: SensorAxes?,
        domain: ClosedRange<Double>,
        value: @escaping (LiveSensorSample) -> SensorAxes,
        thresholds: [Double] = []
    ) -> some View {
        SensorPanel {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                if let current {
                    currentValues(current, unit: unit)
                }
            }

            HStack(spacing: 12) {
                SensorLegend(axis: "X", color: .red)
                SensorLegend(axis: "Y", color: .green)
                SensorLegend(axis: "Z", color: .blue)
                Spacer()
                Text(unit)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            SensorPlotCanvas(
                samples: model.sensorSamples,
                domain: domain,
                series: [
                    SensorPlotSeries(color: .red) { value($0).x },
                    SensorPlotSeries(color: .green) { value($0).y },
                    SensorPlotSeries(color: .blue) { value($0).z },
                ],
                thresholds: thresholds
            )
            .frame(height: 160)
        }
    }

    private func currentValues(_ values: SensorAxes, unit: String) -> some View {
        HStack(spacing: 10) {
            SensorValue(axis: "X", value: values.x, unit: unit, color: .red)
            SensorValue(axis: "Y", value: values.y, unit: unit, color: .green)
            SensorValue(axis: "Z", value: values.z, unit: unit, color: .blue)
        }
    }

    private var detectedTapDescription: String {
        let magnitude = model.lastImpactMagnitude.map {
            " at \($0.formatted(.number.precision(.fractionLength(2)))) g"
        } ?? ""
        if let side = model.lastTapSide {
            let action = model.lastTapTriggeredAction ? "" : " · logging only"
            return "Detected \(side.rawValue) tap\(magnitude)\(action) ·"
        }
        return "Detected calibration tap\(magnitude) ·"
    }

    private var streamStatus: (title: String, symbol: String, color: Color) {
        if !model.isSensorRunning {
            return ("Paused", "pause.circle.fill", .secondary)
        }
        if model.sensorSamples.isEmpty {
            return ("Waiting for samples", "hourglass.circle.fill", .orange)
        }
        if !model.isEnabled {
            return ("Logging only", "waveform.path.ecg", .green)
        }
        return ("Streaming", "dot.radiowaves.left.and.right", .green)
    }

    private var sampleRate: Double? {
        let samples = model.sensorSamples.suffix(100)
        guard
            samples.count > 1,
            let first = samples.first,
            let last = samples.last,
            last.timestamp > first.timestamp
        else { return nil }
        return Double(samples.count - 1) / (last.timestamp - first.timestamp)
    }
}

private struct SensorPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SensorValue: View {
    let axis: String
    let value: Double
    let unit: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(axis) \(value, format: .number.precision(.fractionLength(2))) \(unit)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

private struct SensorLegend: View {
    let axis: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(axis)
        }
        .foregroundStyle(.secondary)
    }
}

private struct SensorPlotSeries {
    let color: Color
    let value: (LiveSensorSample) -> Double

    init(color: Color, value: @escaping (LiveSensorSample) -> Double) {
        self.color = color
        self.value = value
    }
}

/// A fixed-scale Canvas plot avoids the layout and accessibility-tree rebuilds
/// that Swift Charts performs for every mark in every incoming telemetry frame.
private struct SensorPlotCanvas: View {
    let samples: [LiveSensorSample]
    let domain: ClosedRange<Double>
    let series: [SensorPlotSeries]
    var thresholds: [Double]

    init(
        samples: [LiveSensorSample],
        domain: ClosedRange<Double>,
        series: [SensorPlotSeries],
        thresholds: [Double] = []
    ) {
        self.samples = samples
        self.domain = domain
        self.series = series
        self.thresholds = thresholds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let plot = CGRect(
                    x: 40,
                    y: 8,
                    width: max(1, size.width - 46),
                    height: max(1, size.height - 14)
                )
                drawGrid(in: plot, context: &context)
                drawSeries(in: plot, context: &context)
                drawThreshold(in: plot, context: &context)
                drawYLabels(in: plot, context: &context)
            }
            HStack {
                Text("0s")
                Spacer()
                Text("6s")
                Spacer()
                Text("12s")
            }
            .padding(.leading, 40)
            .padding(.trailing, 6)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live sensor plot")
    }

    private func drawGrid(in plot: CGRect, context: inout GraphicsContext) {
        for index in 0...4 {
            let y = plot.minY + plot.height * CGFloat(index) / 4
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.16)), lineWidth: 1)
        }
        for index in 0...6 {
            let x = plot.minX + plot.width * CGFloat(index) / 6
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
        }
    }

    private func drawSeries(in plot: CGRect, context: inout GraphicsContext) {
        guard let firstTimestamp = samples.first?.timestamp else { return }

        for plotSeries in series {
            var path = Path()
            var hasPoint = false
            for sample in samples {
                let elapsed = sample.timestamp - firstTimestamp
                guard elapsed >= 0, elapsed <= SensorChartScale.time.upperBound else { continue }
                let point = CGPoint(
                    x: plot.minX + plot.width * CGFloat(elapsed / SensorChartScale.time.upperBound),
                    y: yPosition(for: plotSeries.value(sample), in: plot)
                )
                if hasPoint {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    hasPoint = true
                }
            }
            context.stroke(path, with: .color(plotSeries.color), lineWidth: 1.35)
        }
    }

    private func drawThreshold(in plot: CGRect, context: inout GraphicsContext) {
        for threshold in thresholds {
            let y = yPosition(for: threshold, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                path,
                with: .color(.orange),
                style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])
            )
        }
    }

    private func drawYLabels(in plot: CGRect, context: inout GraphicsContext) {
        let upper = Text(formatAxisValue(domain.upperBound))
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
        let lower = Text(formatAxisValue(domain.lowerBound))
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
        context.draw(upper, at: CGPoint(x: plot.minX - 5, y: plot.minY), anchor: .trailing)
        context.draw(lower, at: CGPoint(x: plot.minX - 5, y: plot.maxY), anchor: .trailing)
    }

    private func yPosition(for value: Double, in plot: CGRect) -> CGFloat {
        let clampedValue = min(max(value, domain.lowerBound), domain.upperBound)
        let fraction = (clampedValue - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
        return plot.maxY - plot.height * CGFloat(fraction)
    }

    private func formatAxisValue(_ value: Double) -> String {
        if abs(value) < 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.0f", value)
    }
}
