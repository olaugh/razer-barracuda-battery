import XCTest
@testable import RazerBatteryMenuBar

final class BarracudaX2022HardwareTests: XCTestCase {
    /// Explicit opt-in: the normal suite never opens hardware. This verifies
    /// the production IOKit callback/run-loop path on a background thread.
    func testBackgroundHardwareReadWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["RAZER_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Set RAZER_HARDWARE_TEST=1 with a connected, powered-on 1532:0552 headset")
        }
        let done = expectation(description: "Hardware query and route cleanup")
        DispatchQueue.global().async {
            let reading = BarracudaX2022Reader.read()
            XCTAssertEqual(reading?.connected, true)
            XCTAssertNotNil(reading?.battery)
            XCTAssertNotNil(reading?.cableConnected)
            XCTAssertNil(reading?.error)
            print("Hardware battery: \(reading?.battery.map(String.init) ?? "unknown")%")
            done.fulfill()
        }
        wait(for: [done], timeout: 45)
    }

    func testAccessLockRejectsOverlappingQueriesAndReleasesOnClose() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lock")
        defer { try? FileManager.default.removeItem(at: url) }
        var first: BarracudaX2022AccessLock? = try BarracudaX2022AccessLock(url: url)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try BarracudaX2022AccessLock(url: url))
        }
        first = nil
        XCTAssertNoThrow(try BarracudaX2022AccessLock(url: url))
    }
}
