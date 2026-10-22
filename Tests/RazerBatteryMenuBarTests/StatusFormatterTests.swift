import XCTest
@testable import RazerBatteryMenuBar

final class StatusFormatterTests: XCTestCase {
    func testMenuBarDistinguishesUnknownConnectionFromDisconnection() {
        var status = HeadsetStatus.disconnected
        XCTAssertEqual(StatusFormatter.menuBarTitle(status), "🎧 —")

        status.connectionKnown = false
        XCTAssertEqual(StatusFormatter.menuBarTitle(status), "🎧 ?")

        status.connectionKnown = true
        status.isConnected = true
        XCTAssertEqual(StatusFormatter.menuBarTitle(status), "🎧")
    }
}
