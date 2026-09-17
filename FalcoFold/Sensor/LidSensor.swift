import Foundation
import IOKit.hid
import os

/// Reads the hinge angle from the built-in lid angle sensor
/// (HID vendor 0x05AC, product 0x8104, usage page 0x20, usage 0x8A).
///
/// Feature report 1 is `[reportID, angleLow, angleHigh]`: whole degrees, little-endian.
/// The device may push input values when the lid moves. We listen for those and also
/// poll, because a report read costs only a few microseconds.
final class LidSensor {
    /// Called on the main thread with the angle in degrees, only when it changes.
    var onAngle: ((Double) -> Void)?

    private(set) var isAvailable = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: Timer?
    private var lastAngle: Int?
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "LidSensor")

    func start(pollInterval: TimeInterval = 1.0 / 60.0) {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        self.manager = manager

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              readAngle(device) != nil
        else {
            log.error("Lid angle sensor not found")
            isAvailable = false
            return
        }
        self.device = device
        isAvailable = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, _ in
            guard let context else { return }
            let sensor = Unmanaged<LidSensor>.fromOpaque(context).takeUnretainedValue()
            sensor.sample()
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
        lastAngle = nil
    }

    private func sample() {
        guard let device, let angle = readAngle(device), angle != lastAngle else { return }
        lastAngle = angle
        onAngle?(Double(angle))
    }

    private func readAngle(_ device: IOHIDDevice) -> Int? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        return Int(report[1]) | Int(report[2]) << 8
    }
}
