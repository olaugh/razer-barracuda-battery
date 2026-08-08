import Foundation
import IOKit
import IOKit.hid

/// Low-level HID helpers for the Barracuda's control interface (usage page
/// 0xFF13): device lookup and feature/input report I/O. Live battery/charging
/// decoding lives in `HIDStateListener` (async broadcasts); this type just
/// provides the primitives it, the probe, and the monitor share.
enum HIDBatteryReader {

    // MARK: - Device lookup

    /// Finds the USB (dongle) control interface for the Barracuda. Filtering on
    /// Transport == "USB" keeps us on the dongle path; the Bluetooth path is
    /// handled separately via IORegistry BatteryPercent.
    static func findControlDevice() -> IOHIDDevice? {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Razer.vendorID,
            kIOHIDProductIDKey: Razer.productID,
            kIOHIDPrimaryUsagePageKey: Razer.controlUsagePage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        IOHIDManagerOpen(mgr, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return nil }

        // Prefer a USB-transport control interface (the dongle).
        for device in set {
            if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
               transport == "USB" {
                return device
            }
        }
        return set.first
    }

    // MARK: - Feature report I/O

    static func getFeature(_ device: IOHIDDevice, reportID: Int = 0, size: Int = Razer.reportSize,
                           type: IOHIDReportType = kIOHIDReportTypeFeature) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: size)
        var length = size
        let result = IOHIDDeviceGetReport(device, type, CFIndex(reportID), &buffer, &length)
        guard result == kIOReturnSuccess else { return nil }
        return Array(buffer.prefix(length))
    }

    @discardableResult
    static func setFeature(_ device: IOHIDDevice, reportID: Int = 0, _ bytes: [UInt8]) -> Bool {
        let result = bytes.withUnsafeBufferPointer { ptr in
            IOHIDDeviceSetReport(
                device, kIOHIDReportTypeFeature, CFIndex(reportID), ptr.baseAddress!, ptr.count
            )
        }
        return result == kIOReturnSuccess
    }

    // MARK: - Battery / charging queries

}
