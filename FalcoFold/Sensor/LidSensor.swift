import Foundation
import IOKit.hid
import os

/// Reads the hinge angle from the built-in lid angle sensor
/// (HID vendor 0x05AC, product 0x8104, usage page 0x20, usage 0x8A).
///
/// Feature report 1 is `[reportID, angleLow, angleHigh]`: whole degrees, little-endian. The device also
/// pushes the same bytes as input report 1 now and then, which we parse too. A feature-report read costs
/// about 0.4 ms of CPU, so polling runs at 60 Hz only while the lid is near or below the clear angle and
/// drops to 10 Hz while it's wide open. The device is reopened if it goes away and comes back (e.g. sleep).
final class LidSensor {
    static let fastInterval = 1.0 / 60
    static let slowInterval = 1.0 / 10

    /// Called on the main thread with the angle in degrees, only when it changes.
    var onAngle: ((Double) -> Void)?
    /// Called on the main thread when the sensor appears or disappears.
    var onAvailabilityChange: ((Bool) -> Void)?
    /// Poll at the fast rate while the angle is below this, so closing is noticed within a frame.
    var fastPollBelow = 115.0

    private(set) var isAvailable = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: Timer?
    private var pollInterval: TimeInterval = 0
    private var lastAngle: Int?
    /// Buffer for pushed input reports; IOKit keeps this pointer, so it must outlive the device.
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "LidSensor")

    deinit {
        stop()
        reportBuffer.deallocate()
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LidSensor>.fromOpaque(context).takeUnretainedValue().deviceAppeared(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<LidSensor>.fromOpaque(context).takeUnretainedValue().deviceDisappeared(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log.error("IOHIDManagerOpen failed")
            return
        }
        // A device that's already present also arrives through the matching callback, but only once the
        // run loop turns. Open it now so `isAvailable` is right straight after `start()`.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first {
            deviceAppeared(device)
        }
        if !isAvailable { log.error("Lid angle sensor not found") }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pollInterval = 0
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        manager = nil
        lastAngle = nil
    }

    /// Reads the sensor right away, e.g. after waking from sleep.
    func refresh() {
        sample()
    }

    // MARK: Device lifecycle (main run loop)

    private func deviceAppeared(_ device: IOHIDDevice) {
        guard self.device == nil else { return }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              readAngle(device) != nil
        else {
            log.error("Lid angle sensor found but couldn't be read")
            return
        }
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 8, { context, _, _, _, reportID, report, length in
            guard let context, reportID == 1, length >= 3 else { return }
            let angle = Int(report[1]) | Int(report[2]) << 8
            Unmanaged<LidSensor>.fromOpaque(context).takeUnretainedValue().publish(angle, pushed: true)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        log.info("Lid angle sensor ready")
        setAvailable(true)
        sample()
    }

    private func deviceDisappeared(_ device: IOHIDDevice) {
        guard device === self.device else { return }
        log.notice("Lid angle sensor went away")
        timer?.invalidate()
        timer = nil
        pollInterval = 0
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
        lastAngle = nil
        setAvailable(false)
    }

    private func setAvailable(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        onAvailabilityChange?(available)
    }

    // MARK: Reading

    private func sample() {
        guard let device, let angle = readAngle(device) else { return }
        publish(angle, pushed: false)
    }

    private func publish(_ angle: Int, pushed: Bool) {
        if angle != lastAngle {
            lastAngle = angle
            // Shows whether the device pushes reports while the lid moves, or only its idle heartbeat.
            if pushed { log.info("Sensor pushed \(angle)°") }
            onAngle?(Double(angle))
        }
        schedulePoll()
    }

    /// Keeps a repeating timer at the rate the current angle calls for, recreating it only when the rate changes.
    private func schedulePoll() {
        guard device != nil else { return }
        let interval = Double(lastAngle ?? 0) < fastPollBelow ? Self.fastInterval : Self.slowInterval
        guard interval != pollInterval else { return }
        timer?.invalidate()
        pollInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func readAngle(_ device: IOHIDDevice) -> Int? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        return Int(report[1]) | Int(report[2]) << 8
    }
}
