import Foundation
import IOKit
import IOKit.hid

/// C input-report callback → the shared listener (singleton keeps the C shim simple).
private let hidStateCallback: IOHIDReportCallback = { _, _, _, _, _, report, reportLength in
    let n = Int(reportLength)
    var bytes = [UInt8](repeating: 0, count: n)
    for i in 0..<n { bytes[i] = report[i] }
    HIDStateListener.shared.handle(bytes)
}

/// Keeps the dongle's control interface open and listens for the asynchronous
/// input-report broadcasts, demultiplexing the TLV records:
///   byte[10] == 0x21 → battery %   (byte[13])
///   byte[10] == 0x2a → charging     (byte[13] != 0)
///
/// Battery only rides these async 0x21 broadcasts (the 8-byte feature report
/// doesn't reach byte[13]), so a persistent listener is required. Callbacks
/// fire on the main run loop, so all state access here is main-thread-only.
final class HIDStateListener {

    static let shared = HIDStateListener()

    private var device: IOHIDDevice?
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    private(set) var battery: Int?
    private(set) var charging: Bool?
    private(set) var present = false

    /// Invoked (main thread) whenever a broadcast changes battery/charging.
    var onUpdate: (() -> Void)?

    private let batteryDefaultsKey = "com.olaugh.RazerBatteryMenuBar.lastBattery"

    private init() {
        // Seed from the last session so the menu bar isn't blank until the first
        // 0x21 broadcast arrives (they come every ~10 min or on a 1% change).
        let saved = UserDefaults.standard.integer(forKey: batteryDefaultsKey)
        if saved > 0 { battery = saved }
    }

    func start() { openIfNeeded() }

    /// Called on each periodic refresh: ensure the device is open, notice
    /// removal, and demux the latest synchronously-read frame (which is whatever
    /// record was broadcast last — often the 0x21 battery record).
    func poll() {
        openIfNeeded()
        guard device != nil else { present = false; return }
        if HIDBatteryReader.findControlDevice() == nil {
            close(); present = false; return
        }
        present = true
        if let dev = device,
           let frame = HIDBatteryReader.getFeature(dev, reportID: Razer.stateReportID,
                                                    size: Razer.inputReportSize, type: kIOHIDReportTypeInput) {
            demux(frame, notify: false)
        }
    }

    func handle(_ bytes: [UInt8]) {
        demux(bytes, notify: true)
    }

    // MARK: - Device open/close

    private func openIfNeeded() {
        guard device == nil, let dev = HIDBatteryReader.findControlDevice() else { return }
        guard IOHIDDeviceOpen(dev, IOHIDOptionsType(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = dev
        present = true
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, hidStateCallback, nil)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
    }

    private func close() {
        guard let dev = device else { return }
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(dev, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        device = nil
    }

    // MARK: - Decode

    private func demux(_ b: [UInt8], notify: Bool) {
        guard b.count > Razer.valueOffset else { return }
        let key = b[Razer.selectorOffset]
        let value = b[Razer.valueOffset]
        var changed = false

        switch key {
        case Razer.keyBattery:
            if value <= 100, battery != Int(value) {
                battery = Int(value)
                UserDefaults.standard.set(Int(value), forKey: batteryDefaultsKey)
                changed = true
            }
        case Razer.keyCharging:
            let c = (value != 0)
            if charging != c { charging = c; changed = true }
        default:
            break
        }

        if notify && changed { onUpdate?() }
    }
}
