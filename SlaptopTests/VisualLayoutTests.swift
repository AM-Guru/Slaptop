// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Slaptop

@MainActor
final class VisualLayoutTests: XCTestCase {
    func testAboutAnimationWaitsTwoSecondsBeforeFirstTap() {
        XCTAssertEqual(LaptopTapAnimationTimeline.phase(elapsed: 0), 0)
        XCTAssertEqual(LaptopTapAnimationTimeline.phase(elapsed: 1.999), 0)
        XCTAssertEqual(
            LaptopTapAnimationTimeline.phase(elapsed: 2.0),
            LaptopTapAnimationTimeline.firstTapStartPhase,
            accuracy: 0.000_001
        )
    }

    func testMenuBarPresentationIgnoresUnrelatedSensorUIUpdates() {
        let suiteName = "SlaptopMenuBarObservationTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults, automaticallyEnable: false)
        let viewModel = MenuBarViewModel(model: model)
        var updateCount = 0
        let observation = viewModel.objectWillChange.sink { updateCount += 1 }

        model.sensitivity = min(model.sensitivity + 0.01, TapSensitivity.maximum)

        XCTAssertEqual(updateCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testSettingsUsesNativeScrollableContainer() throws {
        let defaults = UserDefaults(suiteName: "SlaptopSettingsScrollTests")!
        defaults.removePersistentDomain(forName: "SlaptopSettingsScrollTests")
        defer { defaults.removePersistentDomain(forName: "SlaptopSettingsScrollTests") }

        let model = AppModel(defaults: defaults, automaticallyEnable: false)
        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        hostingView.frame = CGRect(x: 0, y: 0, width: 520, height: 610)
        hostingView.layoutSubtreeIfNeeded()

        guard let scrollView = firstSubview(of: NSScrollView.self, in: hostingView) else {
            return XCTFail("Settings should contain a native NSScrollView")
        }

        scrollView.layoutSubtreeIfNeeded()
        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = try XCTUnwrap(scrollView.documentView).bounds.height
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertGreaterThan(documentHeight, viewportHeight)

        let maximumOffset = documentHeight - viewportHeight
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0)
    }

    func testPrimaryViewsRenderAtTheirShippingSizes() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SlaptopVisualQA", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "SlaptopVisualLayoutTests")!
        defaults.removePersistentDomain(forName: "SlaptopVisualLayoutTests")
        defer { defaults.removePersistentDomain(forName: "SlaptopVisualLayoutTests") }
        let model = AppModel(defaults: defaults, automaticallyEnable: false)
        try render(
            SettingsView(model: model),
            size: CGSize(width: 520, height: 610),
            to: directory.appendingPathComponent("settings.png")
        )
        try renderScrolledToBottom(
            SettingsView(model: model),
            size: CGSize(width: 520, height: 610),
            to: directory.appendingPathComponent("settings-bottom.png")
        )
        try render(
            AboutView(),
            size: CGSize(width: 500, height: 570),
            to: directory.appendingPathComponent("about.png")
        )
        try render(
            FirstLaunchView(model: model, completeSetup: {}),
            size: CGSize(width: 500, height: 620),
            to: directory.appendingPathComponent("first-launch.png")
        )
        try render(
            SensorDataView(model: model),
            size: CGSize(width: 760, height: 720),
            to: directory.appendingPathComponent("sensor-data.png")
        )
        try render(
            MenuBarView(model: model, showSettings: {}, showAbout: {}, quit: {}),
            size: CGSize(width: 300, height: 300),
            to: directory.appendingPathComponent("menu-bar.png")
        )
        try render(
            LaptopTapAnimationView(phaseOverride: 1.0),
            size: CGSize(width: 500, height: 275),
            to: directory.appendingPathComponent("tap-left.png")
        )
        try render(
            LaptopTapAnimationView(phaseOverride: 4.7),
            size: CGSize(width: 500, height: 275),
            to: directory.appendingPathComponent("tap-right.png")
        )

        for name in [
            "settings.png", "settings-bottom.png", "about.png", "first-launch.png",
            "sensor-data.png", "menu-bar.png",
            "tap-left.png", "tap-right.png",
        ] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 10_000)
        }
    }

    private func render<Content: View>(_ view: Content, size: CGSize, to url: URL) throws {
        let rootView = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Could not create a bitmap for \(url.lastPathComponent)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(url.lastPathComponent)")
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private func renderScrolledToBottom<Content: View>(
        _ view: Content,
        size: CGSize,
        to url: URL
    ) throws {
        let rootView = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: hostingView))
        scrollView.layoutSubtreeIfNeeded()
        let maximumOffset = max(
            0,
            try XCTUnwrap(scrollView.documentView).bounds.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not create a bitmap for \(url.lastPathComponent)")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
