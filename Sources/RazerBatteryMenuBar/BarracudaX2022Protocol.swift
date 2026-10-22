import Foundation

/// The 1532:0552 Macronix dongle uses PA/PI tunnel packets, not Chroma TLVs.
/// Reference and independent hardware observations:
/// https://github.com/leag/razer-barracuda/blob/main/docs/PROTOCOL.md
enum BarracudaX2022Command {
    case link, transport, route, setRoute(Bool), battery, cable

    var family: UInt8 {
        switch self {
        case .battery, .cable: return 0x08
        default: return 0x0E
        }
    }

    private var payload: [UInt8] {
        switch self {
        case .link: return [0xE3]
        case .transport: return [0xE6]
        case .route: return [0xE0]
        case .setRoute(let remote): return [0xE1, remote ? 1 : 0]
        case .battery: return [0x21, 0, 0]
        case .cable: return [0x2A, 0, 0]
        }
    }

    var selector: UInt8 { payload[0] }
    var isTelemetry: Bool { family == 8 }
    var isRouteSelection: Bool {
        if case .setRoute = self { return true }
        return false
    }

    var maximumValue: Int {
        switch self {
        case .battery: return 100
        case .transport: return 255
        default: return 1
        }
    }

    /// Only known reads and volatile route selection are expressible here.
    func report(sequence: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [1, 0x80, UInt8(5 + payload.count), 0x50, 0x41,
                              family, sequence, UInt8(payload.count)] + payload
        bytes += Array(repeating: 0, count: 64 - bytes.count)
        return bytes
    }
}

struct BarracudaX2022Frame {
    let family: UInt8
    let payload: [UInt8]
}

/// Reassembles the tunnel stream before interpreting any field. Media reports
/// may interrupt a fragmented message; invalid/expired fragments are discarded.
struct BarracudaX2022Decoder {
    private var partial: [UInt8] = []
    private var lastChunk: TimeInterval = 0

    mutating func feed(_ report: [UInt8], now: TimeInterval) -> [BarracudaX2022Frame] {
        guard report.first == 1 else { return [] }
        guard report.count >= 3, report[1] == 0x80, report[2] <= 61,
              report.count >= 3 + Int(report[2]) else { partial = []; return [] }
        if now - lastChunk > 2 { partial = [] }
        lastChunk = now
        var frames: [BarracudaX2022Frame] = []
        for byte in report.dropFirst(3).prefix(Int(report[2])) {
            partial.append(byte)
            if (partial.count == 1 && partial[0] != 0x50) ||
               (partial.count == 2 && partial[1] != 0x49) {
                partial = []; return frames
            }
            if partial.count >= 10 {
                let size = 10 + Int(partial[8]) + (Int(partial[9]) << 8)
                guard size <= 256 else { partial = []; return frames }
                if partial.count == size {
                    frames.append(BarracudaX2022Frame(family: partial[2], payload: Array(partial.dropFirst(10))))
                    partial = []
                }
            }
        }
        return frames
    }
}

protocol BarracudaX2022Transport: AnyObject {
    func send(_ report: [UInt8]) throws
    /// Blocks for at most timeout; nil means that the receive window expired.
    func receive(timeout: TimeInterval) throws -> [UInt8]?
}

struct BarracudaX2022Error: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct BarracudaX2022Reading {
    var connected: Bool?
    var battery: Int?
    /// Cable presence is not proof of charge current or charge completion.
    var cableConnected: Bool?
    var error: String?
}

/// One serialized exchange. A session never creates a radio transport or
/// changes pairing/settings. It selects diagnostics only on an existing link.
final class BarracudaX2022Session {
    private let transport: BarracudaX2022Transport
    private var decoder = BarracudaX2022Decoder()
    private var sequence: UInt8 = 0x60

    init(transport: BarracudaX2022Transport) { self.transport = transport }

    func query(_ command: BarracudaX2022Command) throws -> Int {
        let seq = sequence
        sequence = sequence == 0x7F ? 0x60 : sequence + 1
        try transport.send(command.report(sequence: seq))
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var acked = false
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, let report = try transport.receive(timeout: remaining) else {
                throw BarracudaX2022Error("Dongle query timed out")
            }
            for frame in decoder.feed(report, now: ProcessInfo.processInfo.systemUptime) {
                let p = frame.payload
                if command.isTelemetry {
                    // GET replies only: do not satisfy a query with an old broadcast.
                    if frame.family == 8, p.count == 4, p[0] == command.selector,
                       p[1] == 1, p[2] == 1 {
                        return try validated(Int(p[3]), for: command)
                    }
                } else if frame.family == 1, p.count >= 3,
                          p[0] == command.family, p[1] == (seq | 0x80) {
                    guard p[2] == 0 else { throw BarracudaX2022Error("Dongle rejected query") }
                    if command.isRouteSelection { return 0 }
                    acked = true
                } else if acked, frame.family == 0x0E, p.count == 2,
                          p[0] == command.selector {
                    // Data has a device counter, not the host sequence. Accept
                    // it only AFTER the ACK which echoes our host sequence.
                    return try validated(Int(p[1]), for: command)
                }
            }
        }
    }

    private func validated(_ value: Int, for command: BarracudaX2022Command) throws -> Int {
        guard value <= command.maximumValue else { throw BarracudaX2022Error("Invalid dongle status value") }
        return value
    }

    private func setRoute(_ remote: Bool) throws {
        _ = try query(.setRoute(remote))
        guard try query(.route) == (remote ? 1 : 0) else {
            throw BarracudaX2022Error("Diagnostic route verification failed")
        }
    }

    func read() -> BarracudaX2022Reading {
        var reading = BarracudaX2022Reading()
        var selected = false
        do {
            // Runs on all exits after attempting remote selection, even when
            // its ACK is lost. Never return before route cleanup has finished.
            defer {
                if selected {
                    var restored = false
                    for _ in 0..<2 {
                        do { try setRoute(false); restored = true; break }
                        catch { /* bounded cleanup retry only */ }
                    }
                    if !restored {
                        reading.error = "Diagnostic route not restored; replug the USB dongle before retrying"
                    }
                }
            }
            reading.connected = try query(.link) == 1
            if reading.connected == true {
                guard try query(.transport) & 8 != 0 else {
                    throw BarracudaX2022Error("Headset diagnostic transport unavailable")
                }
                guard try query(.route) == 0 else {
                    throw BarracudaX2022Error("Diagnostic route is not local; replug the USB dongle")
                }
                selected = true
                try setRoute(true)
                reading.battery = try query(.battery)
                reading.cableConnected = try query(.cable) == 1
            }
        } catch {
            let message = String(describing: error)
            reading.error = reading.error.map { $0 + "; " + message } ?? message
        }
        return reading
    }
}
