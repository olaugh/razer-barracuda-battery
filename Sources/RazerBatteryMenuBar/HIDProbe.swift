import Foundation
import IOKit
import IOKit.hid

/// Persistent buffer the input-report callback writes into (must outlive the
/// `withUnsafe…` scope since the callback fires asynchronously on the run loop).
private let listenBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

/// C-compatible input-report callback: prints each report as it arrives.
private let inputReportCallback: IOHIDReportCallback = { _, _, _, _, reportID, report, reportLength in
    let n = Int(reportLength)
    var hex = ""
    for i in 0..<n { hex += String(format: "%02x ", report[i]) }
    let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    print("[\(stamp)] IN rid=\(reportID) len=\(n): \(hex)")
}

/// Diagnostic CLI modes used to calibrate the HID protocol against a real
/// headset. Not part of the running menu-bar app.
enum HIDProbe {

    /// `--listen [seconds]`: register an async input-report callback and print
    /// every report the headset pushes. Toggle charging (plug/unplug USB-C)
    /// during the window to see which byte tracks battery/charging.
    static func listen(seconds: Double) {
        guard let device = HIDBatteryReader.findControlDevice() else {
            print("No Razer control device found.")
            return
        }
        guard IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            print("Failed to open device (Input Monitoring permission may be required).")
            return
        }
        defer { IOHIDDeviceClose(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) }

        IOHIDDeviceRegisterInputReportCallback(device, listenBuffer, 64, inputReportCallback, nil)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        print("Listening \(Int(seconds))s for input reports…")
        print("→ Plug in (or unplug) the headset's USB-C charging cable during this window.")
        CFRunLoopRunInMode(.defaultMode, seconds, false)

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, listenBuffer, 64, nil, nil)
        print("Done listening.")
    }

    /// `--snapshot`: synchronously read the device's declared reports and print
    /// them with a byte-index ruler, for diffing across charging/battery states.
    static func snapshot() {
        guard let device = HIDBatteryReader.findControlDevice() else {
            print("No Razer control device found.")
            return
        }
        guard IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            print("Failed to open device.")
            return
        }
        defer { IOHIDDeviceClose(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) }

        print("idx:   " + (0..<64).map { String(format: "%02d", $0) }.joined(separator: " "))
        print("--- FEATURE reports ---")
        dumpReport(device, kIOHIDReportTypeFeature, rid: 0x02, size: 8,  label: "FF14 feat rid02")
        for rid in [0x31, 0x32, 0x33, 0x34, 0x35, 0x36] {
            dumpReport(device, kIOHIDReportTypeFeature, rid: rid, size: 51, label: String(format: "Chroma feat rid%02x", rid))
        }
        print("--- INPUT reports (GetReport) ---")
        dumpReport(device, kIOHIDReportTypeInput, rid: 0x07, size: 61, label: "FF13 input rid07")
        dumpReport(device, kIOHIDReportTypeInput, rid: 0x02, size: 63, label: "FF14 input rid02")
    }

    /// `--watch [seconds]`: poll the 8-byte state report once a second and print
    /// all bytes, so a byte/bit that tracks charging (stable within a cable
    /// state, different across states) can be told apart from counters.
    static func watch(seconds: Double) {
        guard let device = HIDBatteryReader.findControlDevice() else {
            print("No Razer control device found.")
            return
        }
        guard IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            print("Failed to open device.")
            return
        }
        defer { IOHIDDeviceClose(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) }

        print("idx:  " + (0..<8).map { String(format: "%02d", $0) }.joined(separator: " "))
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if let r = HIDBatteryReader.getFeature(device, reportID: Razer.stateReportID, size: Razer.stateReportSize) {
                let hex = r.map { String(format: "%02x", $0) }.joined(separator: " ")
                print(String(format: "[%5.1f] %@", ProcessInfo.processInfo.systemUptime, hex as NSString))
            }
            usleep(1_000_000)
        }
    }

    private static func dumpReport(_ device: IOHIDDevice, _ type: IOHIDReportType, rid: Int, size: Int, label: String) {
        var buf = [UInt8](repeating: 0, count: size)
        var len = size
        let r = IOHIDDeviceGetReport(device, type, CFIndex(rid), &buf, &len)
        guard r == kIOReturnSuccess else {
            print(String(format: "%-16@ <get failed 0x%08x>", label as NSString, r))
            return
        }
        let hex = buf.prefix(len).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("\(label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(hex)")
    }

    /// `--probe`: dump the report descriptor, then sweep feature-report reads
    /// (all report IDs) and the Razer battery/charging command across candidate
    /// transaction IDs.
    static func run() {
        guard let device = HIDBatteryReader.findControlDevice() else {
            print("No Razer control device found (VID 0x1532 / PID 0x0574, usage page 0xFF13).")
            print("Is the dongle plugged in and the headset powered on?")
            return
        }
        print("Found Razer control interface. Opening…")
        guard IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            print("Failed to open device. If macOS prompts for Input Monitoring, grant it and retry.")
            return
        }
        defer { IOHIDDeviceClose(device, IOHIDOptionsType(kIOHIDOptionsTypeNone)) }

        printDeviceInfo(device)
        dumpReportDescriptor(device)

        // 1) Sweep plain feature GETs across report IDs — find any nonzero data.
        print("\n=== Feature GET sweep (report ids 0…15) ===")
        for reportID in 0...15 {
            guard let data = HIDBatteryReader.getFeature(device, reportID: reportID, size: Razer.reportSize),
                  data.contains(where: { $0 != 0 }) else { continue }
            print("reportID \(reportID): \(hexDump(data))")
        }

        // 2) Razer command SET+GET sweep, trying the response on several report IDs.
        let commands: [(String, UInt8)] = [
            ("battery  (0x07/0x80)", Razer.cmdIdBattery),
            ("charging (0x07/0x84)", Razer.cmdIdCharging),
        ]
        for (label, cmdID) in commands {
            print("\n=== \(label) ===")
            for tid in Razer.transactionIDs {
                let cmd = RazerReport(
                    transactionID: tid,
                    commandClass: Razer.cmdClassPower,
                    commandID: cmdID,
                    dataSize: 0x02,
                    arguments: [0x00, 0x00]
                )
                let ok = HIDBatteryReader.setFeature(device, cmd.serialized())
                usleep(30_000)
                let line = String(format: "tid=0x%02x set=%@", tid, ok ? "ok " : "ERR")
                var printed = false
                for reportID in 0...2 {
                    if let resp = HIDBatteryReader.getFeature(device, reportID: reportID, size: Razer.reportSize),
                       resp.contains(where: { $0 != 0 }) {
                        print(line + "  rid\(reportID): " + hexDump(resp))
                        printed = true
                    }
                }
                if !printed { print(line + "  <all-zero>") }
            }
        }

        // 3) Try reading one INPUT report (some devices push battery over input).
        print("\n=== INPUT report read (rid 0…8) ===")
        for reportID in 0...8 {
            var buf = [UInt8](repeating: 0, count: 64)
            var len = buf.count
            let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(reportID), &buf, &len)
            if r == kIOReturnSuccess, buf.prefix(len).contains(where: { $0 != 0 }) {
                print("input rid\(reportID): " + hexDump(Array(buf.prefix(len))))
            }
        }

        print("\nTip: re-run while charging (headset USB-C plugged in) to see which byte flips.")
    }

    /// `--list-devices`: enumerate every HID device and its report sizes.
    static func listDevices() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, nil)
        IOHIDManagerOpen(mgr, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            print("No HID devices found.")
            return
        }
        print("Product                                   VID    PID    UsagePg Usage FeatSz")
        for device in set.sorted(by: { (prop($0, kIOHIDProductKey) ?? "") < (prop($1, kIOHIDProductKey) ?? "") }) {
            let name = prop(device, kIOHIDProductKey) ?? "?"
            print(String(format: "%-40@ 0x%04x 0x%04x 0x%04x %5d %6d",
                         name as NSString,
                         intProp(device, kIOHIDVendorIDKey),
                         intProp(device, kIOHIDProductIDKey),
                         intProp(device, kIOHIDPrimaryUsagePageKey),
                         intProp(device, kIOHIDPrimaryUsageKey),
                         intProp(device, kIOHIDMaxFeatureReportSizeKey)))
        }
    }

    // MARK: - Report descriptor

    private static func dumpReportDescriptor(_ device: IOHIDDevice) {
        print("\n=== HID report descriptor ===")
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            print("<no report descriptor available>")
            return
        }
        let bytes = [UInt8](data)
        print("(\(bytes.count) bytes)\n\(hexDump(bytes))\n")
        parseReportDescriptor(bytes)
    }

    /// Minimal HID report-descriptor walk: prints report IDs and the size of
    /// each Input/Output/Feature main item, plus usage pages/usages.
    private static func parseReportDescriptor(_ bytes: [UInt8]) {
        var i = 0
        var usagePage = 0
        var reportSize = 0
        var reportCount = 0
        var reportID = 0
        var indent = ""

        func mainItem(_ name: String) {
            let bits = reportSize * reportCount
            print("\(indent)\(name)  rid=\(reportID) size=\(reportSize) count=\(reportCount) (\(bits) bits / \(bits/8) bytes)")
        }

        while i < bytes.count {
            let prefix = bytes[i]; i += 1
            let sizeCode = Int(prefix & 0x03)
            let dataLen = sizeCode == 3 ? 4 : sizeCode
            let type = Int((prefix >> 2) & 0x03)
            let tag = Int((prefix >> 4) & 0x0F)
            var value = 0
            for b in 0..<dataLen where i + b < bytes.count {
                value |= Int(bytes[i + b]) << (8 * b)
            }
            i += dataLen

            switch (type, tag) {
            case (0, 0x8): mainItem("Input")
            case (0, 0x9): mainItem("Output")
            case (0, 0xB): mainItem("Feature")
            case (0, 0xA): print("\(indent)Collection (0x\(String(value, radix: 16)))"); indent += "  "
            case (0, 0xC): indent = String(indent.dropLast(2)); print("\(indent)End Collection")
            case (1, 0x0): usagePage = value; print("\(indent)Usage Page 0x\(String(value, radix: 16))")
            case (1, 0x7): reportSize = value
            case (1, 0x8): reportID = value; print("\(indent)Report ID 0x\(String(value, radix: 16))")
            case (1, 0x9): reportCount = value
            case (2, 0x0): print("\(indent)Usage 0x\(String(value, radix: 16)) (page 0x\(String(usagePage, radix: 16)))")
            default: break
            }
        }
    }

    // MARK: - Helpers

    private static func printDeviceInfo(_ device: IOHIDDevice) {
        print("Product:   \(prop(device, kIOHIDProductKey) ?? "?")")
        print("Transport: \(prop(device, kIOHIDTransportKey) ?? "?")")
        print("Feature report size: \(intProp(device, kIOHIDMaxFeatureReportSizeKey)), " +
              "input: \(intProp(device, kIOHIDMaxInputReportSizeKey)), " +
              "output: \(intProp(device, kIOHIDMaxOutputReportSizeKey))")
    }

    private static func prop(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func intProp(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
    }
}
