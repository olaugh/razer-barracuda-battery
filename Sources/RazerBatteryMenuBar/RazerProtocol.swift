import Foundation

/// Constants and report layout for the Razer Barracuda X Chroma.
///
/// Discovered from this machine via `ioreg`/`hidutil`:
///   VID 0x1532, PID 0x0574, control interface on vendor usage page 0xFF13,
///   feature report size = 51 bytes (Razer's newer compact report, not the
///   classic 90-byte one).
enum Razer {
    static let vendorID = 0x1532
    static let productID = 0x0574
    static let controlUsagePage = 0xFF13   // 65299
    static let controlUsage = 0x01
    static let reportSize = 51

    // --- Live state reports on the 0xFF14 vendor collection ---
    //
    // The device exposes an 8-byte feature report (id 0x02) and a 63-byte input
    // report (id 0x02), and *broadcasts* the input report asynchronously on
    // state changes. The input report is a TLV-style record:
    //
    //     02 0a 60 CC 00 00 05 00 80 80 [KEY] 02 01 [VAL] 00 …
    //                                    └byte10    └byte13
    //
    // where byte[10] selects the record and byte[13] carries its value
    // (byte[3] is a sequence counter — ignore it). Confirmed live:
    //     KEY 0x21 → battery percentage (0…100)   e.g. 0x5c = 92%
    //     KEY 0x2a → charging (0x01 charging / 0x00 not)
    //     KEY 0x13 → other status (unused)
    // (byte[2] reads a constant 0x60=96 and is NOT the battery.)
    static let stateReportID = 0x02
    static let stateReportSize = 8
    static let inputReportSize = 63

    static let selectorOffset = 10          // byte[10]: record key
    static let valueOffset = 13             // byte[13]: record value
    static let keyBattery: UInt8 = 0x21
    static let keyCharging: UInt8 = 0x2a

    // Retained only for the monitor's byte-index highlighting/labels.
    static let batteryOffset = 2
    static let counterOffset = 3
    static let chargingOffset = 13

    // --- Legacy Razer command protocol (used only by `--probe` diagnostics) ---
    static let cmdClassPower: UInt8 = 0x07
    static let cmdIdBattery: UInt8 = 0x80
    static let cmdIdCharging: UInt8 = 0x84
    static let transactionIDs: [UInt8] = [0x3f, 0x1f, 0x08, 0x88, 0x00, 0x9f]
}

/// A Razer control report, serialized into a fixed-size buffer.
///
/// Layout (indices into the buffer):
///   [0]        status
///   [1]        transaction_id
///   [2...3]    remaining_packets (big-endian)
///   [4]        protocol_type
///   [5]        data_size
///   [6]        command_class
///   [7]        command_id
///   [8...]     arguments
///   [size-2]   crc  (XOR of bytes [2 ..< size-2])
///   [size-1]   reserved
struct RazerReport {
    var transactionID: UInt8
    var commandClass: UInt8
    var commandID: UInt8
    var dataSize: UInt8
    var arguments: [UInt8]

    func serialized(size: Int = Razer.reportSize) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: size)
        buf[1] = transactionID
        buf[5] = dataSize
        buf[6] = commandClass
        buf[7] = commandID
        for (i, arg) in arguments.enumerated() where (8 + i) < (size - 2) {
            buf[8 + i] = arg
        }
        buf[size - 2] = RazerReport.crc(buf, size: size)
        return buf
    }

    /// Razer CRC: XOR of the report body, excluding the two trailing bytes.
    static func crc(_ buf: [UInt8], size: Int) -> UInt8 {
        var crc: UInt8 = 0
        for i in 2 ..< (size - 2) { crc ^= buf[i] }
        return crc
    }
}

/// Pretty 16-columns-per-row hex dump for probe output.
func hexDump(_ bytes: [UInt8]) -> String {
    var out = ""
    for (i, b) in bytes.enumerated() {
        out += String(format: "%02x ", b)
        if i % 16 == 15 { out += "\n" }
    }
    return out.hasSuffix("\n") ? String(out.dropLast()) : out
}
