import AppKit
import IOKit
import IOKit.hid

/// App delegate for the standalone `--monitor` mode: shows the window and
/// quits the process when it closes.
final class MonitorLauncher: NSObject, NSApplicationDelegate {
    private let monitor = MonitorWindow()
    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.onClose = { NSApp.terminate(nil) }
        monitor.show()
    }
}

/// C input-report callback → routes to the MonitorWindow instance via context.
private let monitorInputCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, reportLength in
    guard let context else { return }
    let monitor = Unmanaged<MonitorWindow>.fromOpaque(context).takeUnretainedValue()
    let n = Int(reportLength)
    var bytes = [UInt8](repeating: 0, count: n)
    for i in 0..<n { bytes[i] = report[i] }
    monitor.didReceiveBroadcast(reportID: Int(reportID), bytes: bytes)
}

/// A live diagnostic window for the Barracuda's HID interface: polls the state
/// reports several times a second, highlights bytes as they change, decodes the
/// candidate fields, and logs the asynchronous input-report broadcasts the
/// headset emits on plug/unplug. Use it to confirm which byte is battery vs
/// charging by watching the values move.
final class MonitorWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var textView: NSTextView?
    private var device: IOHIDDevice?
    private var timer: Timer?

    private let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var broadcasts: [(t: Double, rid: Int, bytes: [UInt8])] = []
    private var prevFeature: [UInt8] = []
    private var prevInput: [UInt8] = []
    private var monBattery: Int?
    private var monCharging: Bool?

    /// Called when the window closes (e.g. to restore the menu-bar app's policy).
    var onClose: (() -> Void)?

    // MARK: - Lifecycle

    func show() {
        if window == nil { buildWindow() }
        openDevice()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Razer Barracuda X Chroma — HID Monitor"
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let scroll = NSScrollView(frame: win.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.backgroundColor = .textBackgroundColor

        scroll.documentView = tv
        win.contentView = scroll
        window = win
        textView = tv
    }

    private func openDevice() {
        guard device == nil, let dev = HIDBatteryReader.findControlDevice() else { return }
        guard IOHIDDeviceOpen(dev, IOHIDOptionsType(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 64, monitorInputCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        if let dev = device {
            IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 64, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            device = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
        onClose?()
    }

    // MARK: - Async broadcasts

    func didReceiveBroadcast(reportID: Int, bytes: [UInt8]) {
        if bytes.count > Razer.valueOffset {
            let key = bytes[Razer.selectorOffset], val = bytes[Razer.valueOffset]
            if key == Razer.keyBattery, val <= 100 { monBattery = Int(val) }
            if key == Razer.keyCharging { monCharging = (val != 0) }
        }
        broadcasts.insert((ProcessInfo.processInfo.systemUptime, reportID, bytes), at: 0)
        if broadcasts.count > 60 { broadcasts.removeLast(broadcasts.count - 60) }
        refresh()
    }

    // MARK: - Rendering

    private func refresh() {
        guard let dev = device, let tv = textView else { return }
        let feature = HIDBatteryReader.getFeature(dev, reportID: Razer.stateReportID, size: Razer.stateReportSize) ?? []
        let input = HIDBatteryReader.getFeature(dev, reportID: Razer.stateReportID, size: Razer.inputReportSize, type: kIOHIDReportTypeInput) ?? []

        let out = NSMutableAttributedString()
        out.append(line("Razer Barracuda X Chroma — live HID monitor", .labelColor, 14, bold: true))
        out.append(line("VID 0x1532  PID 0x0574  ·  0xFF14 collection, report id 0x02", .secondaryLabelColor, 11))
        out.append(line(""))

        appendByteRow(out, "FEATURE report 0x02 (8 bytes):", feature, prev: prevFeature, highlight: [2, 3])
        appendByteRow(out, "INPUT report 0x02 (63 bytes, also broadcast on change):", input, prev: prevInput, highlight: [2, 3, Razer.chargingOffset])

        // Decoded view (TLV: byte[10] = record key, byte[13] = value).
        let src = input.isEmpty ? feature : input
        out.append(line(""))
        out.append(line("Decoded  (TLV record: byte[10]=key, byte[13]=value)", .labelColor, 12, bold: true))
        out.append(decoded("byte[2]  header    ", src, 2, note: "02 0a 60 header — NOT battery", .systemGray))
        out.append(decoded("byte[3]  seq count ", src, 3, note: "event counter — ignore", .systemGray))
        out.append(decoded("byte[10] record key", src, Razer.selectorOffset, note: "0x21=battery · 0x2a=charging · 0x13=power-evt", .systemTeal))
        out.append(decoded("byte[13] value     ", src, Razer.valueOffset, note: "meaning set by the key", .systemTeal))
        out.append(line(""))
        let batStr = monBattery.map { "\($0)%" } ?? "— (waiting for a 0x21 broadcast)"
        let chgStr = monCharging.map { $0 ? "yes ⚡" : "no" } ?? "—"
        out.append(line("  ► Battery (key 0x21):  \(batStr)", .systemGreen, 13, bold: true))
        out.append(line("  ► Charging (key 0x2a): \(chgStr)", .systemGreen, 13, bold: true))
        out.append(line(""))
        out.append(line("→ Plug / unplug the USB-C cable to trigger broadcasts (bytes flash orange).", .secondaryLabelColor, 11))
        out.append(line(""))

        out.append(line("Async input-report broadcasts (newest first):", .labelColor, 12, bold: true))
        if broadcasts.isEmpty {
            out.append(line("   (none yet — plug or unplug the cable to trigger one)", .tertiaryLabelColor, 11))
        }
        let now = ProcessInfo.processInfo.systemUptime
        for b in broadcasts {
            let age = String(format: "%6.1fs", now - b.t)
            let key = b.bytes.count > Razer.selectorOffset ? b.bytes[Razer.selectorOffset] : 0
            let val = b.bytes.count > Razer.valueOffset ? b.bytes[Razer.valueOffset] : 0
            var meaning: String
            var color: NSColor
            switch key {
            case Razer.keyBattery:  meaning = "battery \(val)%";                    color = .systemTeal
            case Razer.keyCharging: meaning = val != 0 ? "charging ⚡" : "not charging"; color = .systemGreen
            case 0x13:              meaning = "power-event (\(val))";               color = .systemOrange
            default:                meaning = "key 0x\(String(format: "%02x", key))"; color = .labelColor
            }
            let hex = b.bytes.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
            out.append(line(String(format: "  [%@ ago] key=0x%02x val=0x%02x  %-16@ %@…",
                                    age, key, val, meaning as NSString, hex as NSString), color, 11))
        }

        tv.textStorage?.setAttributedString(out)
        prevFeature = feature
        prevInput = input
    }

    // MARK: - Attributed-string helpers

    private func mono(_ str: String, _ color: NSColor, _ size: CGFloat, bold: Bool = false) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        return NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color])
    }

    private func line(_ str: String, _ color: NSColor = .labelColor, _ size: CGFloat = 12, bold: Bool = false) -> NSAttributedString {
        mono(str + "\n", color, size, bold: bold)
    }

    /// One "label / ruler / values" block with changed bytes in orange and
    /// candidate offsets underlined-ish via a highlight color.
    private func appendByteRow(_ out: NSMutableAttributedString, _ label: String, _ bytes: [UInt8], prev: [UInt8], highlight: Set<Int>) {
        out.append(line(label, .secondaryLabelColor, 11))
        var ruler = "  idx  "
        for i in 0..<bytes.count { ruler += String(format: "%02d ", i) }
        out.append(mono(ruler + "\n", .tertiaryLabelColor, 10))

        let vals = NSMutableAttributedString(attributedString: mono("  val  ", .secondaryLabelColor, 10))
        for i in 0..<bytes.count {
            let changed = i < prev.count && prev[i] != bytes[i]
            let color: NSColor = changed ? .systemOrange : (highlight.contains(i) ? .systemTeal : .labelColor)
            vals.append(mono(String(format: "%02x ", bytes[i]), color, 11, bold: changed || highlight.contains(i)))
        }
        vals.append(mono("\n", .labelColor, 11))
        out.append(vals)
    }

    private func decoded(_ label: String, _ bytes: [UInt8], _ idx: Int, note: String, _ color: NSColor) -> NSAttributedString {
        guard idx < bytes.count else { return line("  \(label)  = (n/a)", .tertiaryLabelColor, 11) }
        let v = bytes[idx]
        let s = NSMutableAttributedString(attributedString: mono("  \(label)  = ", .labelColor, 11))
        s.append(mono(String(format: "0x%02x (%d)", v, v), color, 11, bold: true))
        s.append(mono("   \(note)\n", .tertiaryLabelColor, 11))
        return s
    }
}
