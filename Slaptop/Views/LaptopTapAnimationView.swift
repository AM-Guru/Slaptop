// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import SwiftUI

enum LaptopTapAnimationTimeline {
    static let initialIdleDuration = 2.0
    static let cycleDuration = 7.2
    static let firstTapStartPhase = 0.45

    static func phase(elapsed: TimeInterval) -> Double {
        guard elapsed >= initialIdleDuration else { return 0 }
        return (elapsed - initialIdleDuration + firstTapStartPhase)
            .truncatingRemainder(dividingBy: cycleDuration)
    }
}

struct LaptopTapAnimationView: View {
    private let phaseOverride: Double?
    @State private var animationStartedAt = Date()

    init(phaseOverride: Double? = nil) {
        self.phaseOverride = phaseOverride
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let phase = phaseOverride
                ?? LaptopTapAnimationTimeline.phase(
                    elapsed: timeline.date.timeIntervalSince(animationStartedAt)
                )

            VStack(spacing: 4) {
                Canvas { context, size in
                    drawLaptop(in: &context, size: size, phase: phase)
                }
                .accessibilityHidden(true)

                Text(caption(for: phase))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .onAppear {
            if phaseOverride == nil {
                animationStartedAt = Date()
            }
        }
    }

    private func drawLaptop(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let screen = CGRect(
            x: size.width * 0.19,
            y: size.height * 0.08,
            width: size.width * 0.62,
            height: size.height * 0.64
        )

        let swap = desktopOffset(phase: phase, width: screen.width)
        let jiggle = screenJiggle(phase: phase)
        let screenTransform = CGAffineTransform(translationX: jiggle, y: 0)

        context.drawLayer { layer in
            layer.transform = screenTransform
            let outer = Path(roundedRect: screen.insetBy(dx: -7, dy: -7), cornerRadius: 13)
            layer.fill(outer, with: .color(.primary.opacity(0.92)))

            let displayPath = Path(roundedRect: screen, cornerRadius: 7)
            layer.clip(to: displayPath)
            layer.fill(displayPath, with: .color(.black.opacity(0.82)))

            drawDesktop(in: &layer, rect: screen.offsetBy(dx: swap, dy: 0), color: .blue, index: 1)
            drawDesktop(in: &layer, rect: screen.offsetBy(dx: swap + screen.width, dy: 0), color: .purple, index: 2)
        }

        var camera = Path()
        camera.addEllipse(in: CGRect(x: screen.midX - 2, y: screen.minY - 4, width: 4, height: 4))
        context.fill(camera, with: .color(.white.opacity(0.6)))

        var base = Path()
        let baseY = screen.maxY + 9
        base.move(to: CGPoint(x: screen.minX - 35, y: baseY))
        base.addLine(to: CGPoint(x: screen.maxX + 35, y: baseY))
        base.addQuadCurve(
            to: CGPoint(x: screen.maxX + 17, y: baseY + 16),
            control: CGPoint(x: screen.maxX + 32, y: baseY + 15)
        )
        base.addLine(to: CGPoint(x: screen.minX - 17, y: baseY + 16))
        base.addQuadCurve(
            to: CGPoint(x: screen.minX - 35, y: baseY),
            control: CGPoint(x: screen.minX - 32, y: baseY + 15)
        )
        context.stroke(base, with: .color(.primary.opacity(0.85)), lineWidth: 3)

        drawHand(in: &context, screen: screen, phase: phase, side: .left)
        drawHand(in: &context, screen: screen, phase: phase, side: .right)
    }

    private func drawDesktop(
        in context: inout GraphicsContext,
        rect: CGRect,
        color: Color,
        index: Int
    ) {
        let gradient = Gradient(colors: [color.opacity(0.82), color.opacity(0.32)])
        context.fill(
            Path(rect),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )

        let window = CGRect(
            x: rect.minX + rect.width * (index == 1 ? 0.12 : 0.25),
            y: rect.minY + rect.height * 0.18,
            width: rect.width * 0.62,
            height: rect.height * 0.58
        )
        context.fill(Path(roundedRect: window, cornerRadius: 6), with: .color(.white.opacity(0.82)))

        let toolbar = CGRect(x: window.minX, y: window.minY, width: window.width, height: 14)
        context.fill(Path(roundedRect: toolbar, cornerRadius: 6), with: .color(.white.opacity(0.95)))
        for dot in 0..<3 {
            let circle = CGRect(x: toolbar.minX + 9 + CGFloat(dot) * 10, y: toolbar.midY - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: circle), with: .color(color.opacity(0.75)))
        }

        for row in 0..<3 {
            let line = CGRect(
                x: window.minX + 13,
                y: window.minY + 30 + CGFloat(row) * 16,
                width: window.width * (row == 1 ? 0.50 : 0.68),
                height: 4
            )
            context.fill(Path(roundedRect: line, cornerRadius: 2), with: .color(color.opacity(0.25)))
        }
    }

    private func drawHand(
        in context: inout GraphicsContext,
        screen: CGRect,
        phase: Double,
        side: TapSide
    ) {
        let window: ClosedRange<Double> = side == .left ? 0.45...1.55 : 4.15...5.25
        guard window.contains(phase) else { return }

        let local = (phase - window.lowerBound) / (window.upperBound - window.lowerBound)
        let approach = local < 0.5 ? ease(local / 0.5) : ease((1 - local) / 0.5)
        let visibility = sin(local * .pi)
        let direction: CGFloat = side == .left ? 1 : -1
        let edgeX = side == .left ? screen.minX : screen.maxX
        let contact = CGPoint(
            x: edgeX,
            y: screen.minY + screen.height * 0.40
        )
        let handCenter = CGPoint(
            x: edgeX - direction * (62 - 31 * approach),
            y: contact.y + 4
        )

        context.drawLayer { layer in
            layer.opacity = visibility

            let symbolName = side == .left ? "hand.point.right" : "hand.point.left"
            var hand = layer.resolve(Image(systemName: symbolName))
            hand.shading = .color(.primary.opacity(0.88))
            layer.draw(
                hand,
                in: CGRect(
                    x: handCenter.x - 34,
                    y: handCenter.y - 23,
                    width: 68,
                    height: 46
                )
            )
        }

        if approach > 0.82 {
            let pulse = (approach - 0.82) / 0.18
            for ring in 0..<2 {
                let radius = 5 + CGFloat(ring) * 6 + CGFloat(1 - pulse) * 3
                let arc = CGRect(
                    x: contact.x - radius,
                    y: contact.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.stroke(Path(ellipseIn: arc), with: .color(.accentColor.opacity(0.55 - Double(ring) * 0.18)), lineWidth: 1.5)
            }
        }
    }

    private func desktopOffset(phase: Double, width: CGFloat) -> CGFloat {
        if phase < 1.25 { return 0 }
        if phase < 2.15 { return -width * CGFloat(ease((phase - 1.25) / 0.90)) }
        if phase < 4.90 { return -width }
        if phase < 5.80 { return -width * CGFloat(1 - ease((phase - 4.90) / 0.90)) }
        return 0
    }

    private func screenJiggle(phase: Double) -> CGFloat {
        let tapTime = phase < 3.2 ? 1.18 : 4.88
        let delta = phase - tapTime
        guard delta >= 0, delta < 0.42 else { return 0 }
        let direction: Double = tapTime < 2 ? 1 : -1
        return CGFloat(direction * sin(delta * 42) * (1 - delta / 0.42) * 2.7)
    }

    private func caption(for phase: Double) -> String {
        switch phase {
        case 0.45..<2.9: return "Tap left  →  Switch Space: Right"
        case 4.15..<6.25: return "Tap right  →  Switch Space: Left"
        default: return "A tiny tap is all it takes"
        }
    }

    private func ease(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
