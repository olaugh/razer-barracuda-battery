import XCTest
@testable import RazerBatteryMenuBar

final class BatteryMonitorTests: XCTestCase {
    func testRefreshDoesNotBlockMainThreadAndCoalescesConcurrentQueries() {
        let done = expectation(description: "Both refresh callers receive the reading")
        done.expectedFulfillmentCount = 2
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var reads = 0
        let monitor = BatteryMonitor(dongleRead: {
            XCTAssertFalse(Thread.isMainThread)
            reads += 1
            started.signal()
            _ = release.wait(timeout: .now() + 3)
            return BarracudaX2022Reading(connected: true, battery: 61, cableConnected: false)
        }, fallbackRead: { .disconnected })
        let callback: (HeadsetStatus) -> Void = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(status.batteryPercent, 61)
            done.fulfill()
        }
        monitor.refresh(callback)
        monitor.refresh(callback)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        release.signal()
        wait(for: [done], timeout: 4)
        XCTAssertEqual(reads, 1)
    }

    func testChromaStatusDoesNotTrigger2022Queries() {
        var chroma = HeadsetStatus.disconnected
        chroma.isConnected = true
        chroma.connection = .dongle
        chroma.batteryPercent = 80
        let monitor = BatteryMonitor(dongleRead: {
            XCTFail("Chroma must retain its existing reader")
            return nil
        }, fallbackRead: { chroma })
        XCTAssertEqual(monitor.readNow().batteryPercent, 80)
    }

    func testShutdownWaitsForInFlightReadCleanup() {
        let stopped = expectation(description: "Shutdown after cleanup")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var cleanedUp = false
        let monitor = BatteryMonitor(dongleRead: {
            started.signal()
            _ = release.wait(timeout: .now() + 3)
            cleanedUp = true
            return nil
        }, fallbackRead: { .disconnected })
        monitor.refresh { _ in }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        monitor.stop {
            XCTAssertTrue(cleanedUp)
            stopped.fulfill()
        }
        release.signal()
        wait(for: [stopped], timeout: 4)
        monitor.refresh { _ in XCTFail("No new refreshes after shutdown") }
    }

    func testChromaAppearingDuringQueryKeepsPriorityOverOlder2022Read() {
        let done = expectation(description: "Current Chroma state wins")
        let release = DispatchSemaphore(value: 0)
        var fallback = HeadsetStatus.disconnected
        let monitor = BatteryMonitor(dongleRead: {
            _ = release.wait(timeout: .now() + 3)
            return BarracudaX2022Reading(connected: true, battery: 61)
        }, fallbackRead: { fallback })
        monitor.refresh { status in
            XCTAssertEqual(status.batteryPercent, 80)
            done.fulfill()
        }
        fallback.isConnected = true
        fallback.connection = .dongle
        fallback.batteryPercent = 80
        release.signal()
        wait(for: [done], timeout: 4)
    }

    func testChromaAppearingDuringQueryPreservesCleanupWarning() {
        let done = expectation(description: "Chroma telemetry retains the 2022 cleanup warning")
        let release = DispatchSemaphore(value: 0)
        var fallback = HeadsetStatus.disconnected
        let monitor = BatteryMonitor(dongleRead: {
            _ = release.wait(timeout: .now() + 3)
            return BarracudaX2022Reading(connected: true, battery: 61,
                                        error: "Diagnostic route not restored; replug the USB dongle")
        }, fallbackRead: { fallback })
        monitor.refresh { status in
            XCTAssertEqual(status.batteryPercent, 80)
            XCTAssertEqual(status.connection, .dongle)
            XCTAssertEqual(status.diagnosticMessage, "Diagnostic route not restored; replug the USB dongle")
            done.fulfill()
        }
        fallback.isConnected = true
        fallback.connection = .dongle
        fallback.batteryPercent = 80
        release.signal()
        wait(for: [done], timeout: 4)
    }

    func testReadNowKeepsBluetoothWhen2022DongleIsDisconnectedOrUnreadable() {
        var bluetooth = HeadsetStatus.disconnected
        bluetooth.isConnected = true
        bluetooth.connection = .bluetooth
        bluetooth.batteryPercent = 72
        for connected in [false, nil] as [Bool?] {
            let monitor = BatteryMonitor(dongleRead: {
                BarracudaX2022Reading(connected: connected)
            }, fallbackRead: { bluetooth })
            let status = monitor.readNow()
            XCTAssertEqual(status.connection, .bluetooth)
            XCTAssertEqual(status.batteryPercent, 72)
        }
    }

    func testRefreshKeepsBluetoothAndPreservesDongleCleanupWarning() {
        let done = expectation(description: "Bluetooth fallback with actionable diagnostic")
        done.expectedFulfillmentCount = 2
        var bluetooth = HeadsetStatus.disconnected
        bluetooth.isConnected = true
        bluetooth.connection = .bluetooth
        bluetooth.batteryPercent = 72
        let monitors = [false, nil] as [Bool?]
        // Retain both monitors until their asynchronous refreshes finish.
        let readers = monitors.map { connected in
            BatteryMonitor(dongleRead: {
                BarracudaX2022Reading(connected: connected, error: "replug dongle")
            }, fallbackRead: { bluetooth })
        }
        for monitor in readers {
            monitor.refresh { status in
                XCTAssertEqual(status.connection, .bluetooth)
                XCTAssertEqual(status.batteryPercent, 72)
                XCTAssertEqual(status.diagnosticMessage, "replug dongle")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 4)
    }
}
