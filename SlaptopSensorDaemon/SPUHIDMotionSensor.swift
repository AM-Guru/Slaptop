// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

enum SPUSensorError: LocalizedError {
    case sensorNotFound
    case permissionDenied(IOReturn)
    case configurationFailed(IOReturn)
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .sensorNotFound:
            return "No compatible AppleSPU motion sensor was found. Slaptop requires an Apple Silicon Mac with an integrated screen."
        case let .permissionDenied(code):
            return "The AppleSPU sensor could not be opened (IOKit \(code))."
        case let .configurationFailed(code):
            return "The AppleSPU sensor could not be configured (IOKit \(code))."
        case .startTimedOut:
            return "The AppleSPU sensor did not start in time."
        }
    }
}

final class SPUHIDMotionSensor {
    var onImpact: ((MotionFeatureDetector.Detection) -> Void)? {
        didSet { detector.onDetection = onImpact }
    }
    var onSample: ((SensorVector, SensorVector, Double, TimeInterval) -> Void)?

    private enum SensorKind {
        case accelerometer
        case gyroscope
    }

    private final class CallbackContext {
        unowned let owner: SPUHIDMotionSensor
        let kind: SensorKind

        init(owner: SPUHIDMotionSensor, kind: SensorKind) {
            self.owner = owner
            self.kind = kind
        }
    }

    private struct OpenDevice {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let context: CallbackContext
    }

    private static let vendorUsagePage = 0xFF00
    private static let accelerometerUsage = 3
    private static let gyroscopeUsage = 9
    private static let reportLength = 22
    private static let reportBufferSize = 4096
    private static let payloadOffset = 6
    private static let scale = 65_536.0

    private let detector = MotionFeatureDetector()
    private let stateLock = NSLock()
    /// Serializes start() so two clients cannot spawn two sensor threads.
    private let startLock = NSLock()
    private var shouldStop = false
    /// Incremented for every sensor thread. A thread that observes a newer
    /// generation exits and leaves the shared state to its successor.
    private var runGeneration = 0
    private var sensorThread: Thread?
    private var sensorThreadExit: DispatchSemaphore?
    private var sensorRunLoop: CFRunLoop?
    private var latestAcceleration = SensorVector.zero
    private var latestGyroscope = SensorVector.zero
    private var latestImpactMagnitude = 0.0
    private var lastTelemetryAt: TimeInterval = -.infinity
    private var hasLoggedFirstReport = false
    private var unexpectedReportLengths: Set<Int> = []

    /// UI telemetry is intentionally much slower than the raw HID stream.
    private let telemetryInterval: TimeInterval = 1.0 / 25.0

    var isAvailable: Bool {
        let services = Self.enumerateServices(className: "AppleSPUHIDDevice")
        defer { Self.releaseServices(services) }
        return services.contains { service in
            Self.integerProperty("PrimaryUsagePage", service: service) == Self.vendorUsagePage
                && Self.integerProperty("PrimaryUsage", service: service) == Self.accelerometerUsage
        }
    }

    var isRunning: Bool {
        stateLock.withLock { sensorThread != nil && !shouldStop }
    }

    func setSensitivity(_ value: Double) {
        detector.setSensitivity(value)
    }

    func setMinimumTapInterval(_ value: TimeInterval) {
        detector.setMinimumTapInterval(value)
    }

    func start() throws {
        startLock.lock()
        defer { startLock.unlock() }

        if isRunning { return }
        // A previous thread may still be winding down after stop(); wait for
        // it so the HID devices are not opened twice and its exit cannot
        // clobber the new thread's shared state.
        waitForPreviousThreadExit()

        detector.reset()
        let exitSignal = DispatchSemaphore(value: 0)
        var generation = 0
        stateLock.withLock {
            shouldStop = false
            runGeneration += 1
            generation = runGeneration
            sensorThreadExit = exitSignal
            latestAcceleration = .zero
            latestGyroscope = .zero
            latestImpactMagnitude = 0
            lastTelemetryAt = -.infinity
            hasLoggedFirstReport = false
            unexpectedReportLengths.removeAll()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var startError: Error?

        let thread = Thread { [weak self] in
            defer { exitSignal.signal() }
            guard let self else {
                semaphore.signal()
                return
            }
            do {
                try self.runSensorLoop(started: semaphore, generation: generation)
            } catch {
                resultLock.withLock { startError = error }
                semaphore.signal()
            }
            self.stateLock.withLock {
                guard self.runGeneration == generation else { return }
                self.sensorThread = nil
                self.sensorRunLoop = nil
                self.sensorThreadExit = nil
            }
        }
        thread.name = "Slaptop AppleSPU Sensor"
        thread.qualityOfService = .userInteractive
        stateLock.withLock { sensorThread = thread }
        thread.start()

        guard semaphore.wait(timeout: .now() + 3) == .success else {
            stop()
            throw SPUSensorError.startTimedOut
        }
        if let error = resultLock.withLock({ startError }) {
            throw error
        }
    }

    private func waitForPreviousThreadExit() {
        let (exitSignal, runLoop): (DispatchSemaphore?, CFRunLoop?) = stateLock.withLock {
            guard sensorThread != nil else { return (nil, nil) }
            shouldStop = true
            return (sensorThreadExit, sensorRunLoop)
        }
        guard let exitSignal else { return }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        _ = exitSignal.wait(timeout: .now() + 2)
    }

    func stop() {
        let runLoop = stateLock.withLock { () -> CFRunLoop? in
            shouldStop = true
            return sensorRunLoop
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runSensorLoop(started semaphore: DispatchSemaphore, generation: Int) throws {
        try wakeSensorDrivers()

        guard let runLoop = CFRunLoopGetCurrent() else {
            throw SPUSensorError.configurationFailed(kIOReturnError)
        }
        stateLock.withLock {
            if runGeneration == generation { sensorRunLoop = runLoop }
        }
        var openDevices: [OpenDevice] = []
        var openFailure: IOReturn?

        let services = Self.enumerateServices(className: "AppleSPUHIDDevice")
        defer { Self.releaseServices(services) }
        for service in services {
            guard
                Self.integerProperty("PrimaryUsagePage", service: service) == Self.vendorUsagePage,
                let usage = Self.integerProperty("PrimaryUsage", service: service)
            else { continue }

            let kind: SensorKind
            switch usage {
            case Self.accelerometerUsage: kind = .accelerometer
            case Self.gyroscopeUsage: kind = .gyroscope
            default: continue
            }

            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                openFailure = result
                continue
            }

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferSize)
            buffer.initialize(repeating: 0, count: Self.reportBufferSize)
            let context = CallbackContext(owner: self, kind: kind)
            let contextPointer = Unmanaged.passUnretained(context).toOpaque()

            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device,
                buffer,
                Self.reportBufferSize,
                Self.inputReportCallback,
                contextPointer
            )
            IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            openDevices.append(OpenDevice(device: device, buffer: buffer, context: context))
        }

        guard openDevices.contains(where: { $0.context.kind == .accelerometer }) else {
            cleanup(openDevices, runLoop: runLoop)
            if let openFailure { throw SPUSensorError.permissionDenied(openFailure) }
            throw SPUSensorError.sensorNotFound
        }

        NSLog(
            "Slaptop AppleSPU sensor opened %d device(s), including accelerometer=%@ and gyroscope=%@",
            openDevices.count,
            openDevices.contains(where: { $0.context.kind == .accelerometer }) ? "yes" : "no",
            openDevices.contains(where: { $0.context.kind == .gyroscope }) ? "yes" : "no"
        )

        semaphore.signal()

        while !stateLock.withLock({ shouldStop || runGeneration != generation }) {
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }

        cleanup(openDevices, runLoop: runLoop)
    }

    private func cleanup(_ devices: [OpenDevice], runLoop: CFRunLoop) {
        for openDevice in devices {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                openDevice.device,
                openDevice.buffer,
                Self.reportBufferSize,
                nil,
                nil
            )
            IOHIDDeviceUnscheduleFromRunLoop(
                openDevice.device,
                runLoop,
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDDeviceClose(openDevice.device, IOOptionBits(kIOHIDOptionsTypeNone))
            openDevice.buffer.deinitialize(count: Self.reportBufferSize)
            openDevice.buffer.deallocate()
        }
    }

    private func wakeSensorDrivers() throws {
        let services = Self.enumerateServices(className: "AppleSPUHIDDriver")
        defer { Self.releaseServices(services) }
        for service in services {
            for (key, value) in [
                ("SensorPropertyReportingState", 1),
                ("SensorPropertyPowerState", 1),
                ("ReportInterval", 1_000),
            ] {
                let result = IORegistryEntrySetCFProperty(
                    service,
                    key as CFString,
                    NSNumber(value: value)
                )
                guard result == kIOReturnSuccess else {
                    throw SPUSensorError.configurationFailed(result)
                }
            }
        }
    }

    private func handleReport(kind: SensorKind, report: UnsafeMutablePointer<UInt8>?, length: CFIndex) {
        guard let report else { return }
        guard length == Self.reportLength else {
            if unexpectedReportLengths.insert(length).inserted {
                NSLog("Slaptop ignored an unexpected AppleSPU report length: %d bytes", length)
            }
            return
        }
        if !hasLoggedFirstReport {
            hasLoggedFirstReport = true
            NSLog("Slaptop received its first valid AppleSPU motion report.")
        }
        let vector = SensorVector(
            x: Self.readInt32(report, offset: Self.payloadOffset) / Self.scale,
            y: Self.readInt32(report, offset: Self.payloadOffset + 4) / Self.scale,
            z: Self.readInt32(report, offset: Self.payloadOffset + 8) / Self.scale
        )
        let time = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .accelerometer:
            latestAcceleration = vector
            latestImpactMagnitude = detector.consumeAcceleration(vector, time: time)
        case .gyroscope:
            latestGyroscope = vector
            detector.consumeGyroscope(vector, time: time)
        }

        if time - lastTelemetryAt >= telemetryInterval {
            lastTelemetryAt = time
            onSample?(latestAcceleration, latestGyroscope, latestImpactMagnitude, time)
        }
    }

    private static let inputReportCallback: IOHIDReportWithTimeStampCallback = {
        context, result, _, _, _, report, reportLength, _ in
        guard result == kIOReturnSuccess, let context else { return }
        let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
        callbackContext.owner.handleReport(
            kind: callbackContext.kind,
            report: report,
            length: reportLength
        )
    }

    private static func readInt32(_ bytes: UnsafeMutablePointer<UInt8>, offset: Int) -> Double {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1]) << 8
        let b2 = UInt32(bytes[offset + 2]) << 16
        let b3 = UInt32(bytes[offset + 3]) << 24
        return Double(Int32(bitPattern: b0 | b1 | b2 | b3))
    }

    private static func enumerateServices(className: String) -> [io_service_t] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            services.append(service)
        }
        return services
    }

    private static func releaseServices(_ services: [io_service_t]) {
        for service in services { IOObjectRelease(service) }
    }

    private static func integerProperty(_ key: String, service: io_service_t) -> Int? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = unmanaged.takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }
}
