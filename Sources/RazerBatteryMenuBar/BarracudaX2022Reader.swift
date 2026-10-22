import Foundation
import IOKit
import IOKit.hid
import Darwin

private let barracudaX2022Input: IOHIDReportCallback = { context, result, _, _, _, report, length in
    guard let context else { return }
    let transport = Unmanaged<BarracudaX2022HIDTransport>.fromOpaque(context).takeUnretainedValue()
    transport.received(result: result, bytes: Array(UnsafeBufferPointer(start: report, count: length)))
}

/// Owns a callback buffer and run loop for one transaction. Keep its lifetime
/// within one synchronous invocation on the creating thread (worker or --once).
private final class BarracudaX2022HIDTransport: BarracudaX2022Transport {
    private let device: IOHIDDevice
    private let runLoop = CFRunLoopGetCurrent()!
    private let buffer: UnsafeMutablePointer<UInt8>
    private var reports: [[UInt8]] = []
    private var inputError: IOReturn?

    init(device: IOHIDDevice) throws {
        self.device = device
        let result = IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw BarracudaX2022Error(String(format: "Cannot open 2022 dongle (0x%08x)", result))
        }
        // Allocate only once opening succeeds: a throwing initializer does
        // not run deinit, so a raw buffer allocated earlier would leak.
        buffer = .allocate(capacity: 64)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, barracudaX2022Input,
                                              Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        IOHIDDeviceClose(device, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    func received(result: IOReturn, bytes: [UInt8]) {
        if result == kIOReturnSuccess {
            // Bound memory if a device unexpectedly floods its input pipe.
            if reports.count >= 256 { reports.removeFirst() }
            reports.append(bytes)
        } else { inputError = result }
    }

    func send(_ report: [UInt8]) throws {
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else {
            throw BarracudaX2022Error(String(format: "Dongle write failed (0x%08x)", result))
        }
    }

    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while reports.isEmpty && inputError == nil {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return nil }
            CFRunLoopRunInMode(.defaultMode, min(remaining, 0.05), false)
        }
        if let error = inputError {
            throw BarracudaX2022Error(String(format: "Dongle input failed (0x%08x)", error))
        }
        return reports.removeFirst()
    }
}

/// A nonblocking, per-user process lock prevents this app and --once from
/// interleaving diagnostic routes. It cannot coordinate unrelated HID tools.
final class BarracudaX2022AccessLock {
    private let descriptor: Int32

    init(url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BarracudaX2022Error("Cannot open dongle access lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw BarracudaX2022Error("Another battery query is using the dongle; retry shortly")
        }
        descriptor = fd
    }

    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

enum BarracudaX2022Reader {
    /// nil means no 2022 dongle. A present but unreadable dongle yields unknown
    /// telemetry plus an error, never a made-up battery or disconnected state.
    static func read() -> BarracudaX2022Reading? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: 0x0552,
            kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDTransportKey: "USB",
        ] as CFDictionary)
        let result = IOHIDManagerOpen(manager, 0)
        defer { IOHIDManagerClose(manager, 0) }
        guard result == kIOReturnSuccess else {
            return BarracudaX2022Reading(error: String(format: "HID discovery failed (0x%08x)", result))
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !devices.isEmpty else { return nil }
        guard devices.count == 1, let device = devices.first else {
            return BarracudaX2022Reading(error: "Multiple 2022 dongles detected; connect only one")
        }
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.olaugh.RazerBatteryMenuBar", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let access = try BarracudaX2022AccessLock(url: directory.appendingPathComponent("dongle-0552.lock"))
            return try withExtendedLifetime(access) {
                let transport = try BarracudaX2022HIDTransport(device: device)
                return BarracudaX2022Session(transport: transport).read()
            }
        } catch {
            return BarracudaX2022Reading(error: String(describing: error))
        }
    }
}

extension BarracudaX2022Reading {
    func status(audioActive: Bool) -> HeadsetStatus {
        HeadsetStatus(
            isConnected: connected == true,
            batteryPercent: connected == true ? battery : nil,
            isCharging: connected == true ? cableConnected : nil,
            connection: connected == false ? .disconnected : .dongle,
            audioActive: audioActive,
            lastUpdated: Date(),
            connectionKnown: connected != nil,
            diagnosticMessage: error
        )
    }
}
