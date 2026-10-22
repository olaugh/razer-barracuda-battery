import XCTest
@testable import RazerBatteryMenuBar

final class BarracudaX2022Tests: XCTestCase {
    func testCommandsMatchCapturedPackets() {
        XCTAssertEqual(Array(BarracudaX2022Command.link.report(sequence: 0x60).prefix(9)),
                       [1, 0x80, 6, 0x50, 0x41, 0x0E, 0x60, 1, 0xE3])
        XCTAssertEqual(Array(BarracudaX2022Command.battery.report(sequence: 0x65).prefix(11)),
                       [1, 0x80, 8, 0x50, 0x41, 8, 0x65, 3, 0x21, 0, 0])
        XCTAssertEqual(BarracudaX2022Command.cable.report(sequence: 1).count, 64)
        XCTAssertEqual(Array(BarracudaX2022Command.setRoute(false).report(sequence: 0x67).prefix(10)),
                       [1, 0x80, 7, 0x50, 0x41, 0x0E, 0x67, 2, 0xE1, 0])
    }

    func testDecoderReassemblesFragmentedBatteryFrameAndIgnoresMediaKeys() {
        var decoder = BarracudaX2022Decoder()
        XCTAssertTrue(decoder.feed([1, 0x80, 6, 0x50, 0x49, 8, 0xEA, 0xC0, 0xE6], now: 0).isEmpty)
        XCTAssertTrue(decoder.feed([2, 0, 2, 0, 0], now: 0.1).isEmpty)
        let frames = decoder.feed([1, 0x80, 8, 5, 0, 4, 0, 0x21, 1, 1, 0x3D], now: 0.2)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.family, 8)
        XCTAssertEqual(frames.first?.payload, [0x21, 1, 1, 61])
    }

    func testDecoderRejectsMalformedOversizedAndExpiredChunks() {
        var decoder = BarracudaX2022Decoder()
        XCTAssertTrue(decoder.feed([1, 0x80, 62], now: 0).isEmpty)
        XCTAssertTrue(decoder.feed([1, 0x80, 10, 0x50, 0x49, 8, 1, 0, 0, 0, 0, 0xFF, 0xFF], now: 0).isEmpty)
        XCTAssertTrue(decoder.feed([1, 0x80, 3, 0x50, 0x49, 8], now: 0).isEmpty)
        XCTAssertTrue(decoder.feed([1, 0x80, 3, 0, 0, 0], now: 3).isEmpty)
        XCTAssertEqual(decoder.feed(report(family: 8, payload: [0x21, 1, 1, 0]), now: 4).count, 1)
    }

    func testLinkReplyRequiresMatchingAcknowledgmentBeforeData() throws {
        let transport = FakeTransport()
        transport.beforeAck = [report(family: 0x0E, payload: [0xE3, 0])]
        let session = BarracudaX2022Session(transport: transport)
        XCTAssertEqual(try session.query(.link), 1)
    }

    func testRejectedAcknowledgmentAndInvalidTelemetryFail() {
        let transport = FakeTransport()
        transport.rejectLink = true
        XCTAssertThrowsError(try BarracudaX2022Session(transport: transport).query(.link))
        transport.rejectLink = false
        transport.battery = 101
        XCTAssertThrowsError(try BarracudaX2022Session(transport: transport).query(.battery))
        transport.battery = 0
        XCTAssertEqual(try BarracudaX2022Session(transport: transport).query(.battery), 0)
        transport.cable = 2
        XCTAssertThrowsError(try BarracudaX2022Session(transport: transport).query(.cable))
    }

    func testReadReturnsBatteryAndRestoresLocalRoute() {
        let transport = FakeTransport()
        let reading = BarracudaX2022Session(transport: transport).read()
        XCTAssertEqual(reading.connected, true)
        XCTAssertEqual(reading.battery, 61)
        XCTAssertEqual(reading.cableConnected, false)
        XCTAssertNil(reading.error)
        XCTAssertEqual(transport.route, 0)
        XCTAssertEqual(transport.routeWrites, [1, 0])
        XCTAssertEqual(transport.lastRouteRead, 0)
    }

    func testTimeoutStillRestoresRouteAndNeverInventsBattery() {
        let transport = FakeTransport()
        transport.silentBattery = true
        let reading = BarracudaX2022Session(transport: transport).read()
        XCTAssertEqual(reading.connected, true)
        XCTAssertNil(reading.battery)
        XCTAssertNotNil(reading.error)
        XCTAssertEqual(transport.routeWrites, [1, 0])
        XCTAssertEqual(transport.lastRouteRead, 0)
    }

    func testRouteSelectionTimeoutStillAttemptsCleanup() {
        let transport = FakeTransport()
        transport.silentRemoteSelection = true
        let reading = BarracudaX2022Session(transport: transport).read()
        XCTAssertNil(reading.battery)
        XCTAssertEqual(transport.routeWrites, [1, 0])
        XCTAssertEqual(transport.route, 0)
    }

    func testFailedRestorationRetriesOnceAndReportsReplugRequired() {
        let transport = FakeTransport()
        transport.failRestoration = true
        let reading = BarracudaX2022Session(transport: transport).read()
        XCTAssertEqual(transport.routeWrites, [1, 0, 0])
        XCTAssertEqual(reading.battery, 61)
        XCTAssertTrue(reading.error?.contains("replug") == true)
    }

    func testDisconnectedHeadsetDoesNotSelectRouteOrReturnBattery() {
        let transport = FakeTransport()
        transport.link = 0
        let reading = BarracudaX2022Session(transport: transport).read()
        XCTAssertEqual(reading.connected, false)
        XCTAssertNil(reading.battery)
        XCTAssertTrue(transport.routeWrites.isEmpty)
    }

    func testUnknownLinkAndUnsafeInitialRouteDoNotSelectRemoteRoute() {
        let transport = FakeTransport()
        transport.rejectLink = true
        let reading = BarracudaX2022Session(transport: transport).read()
        XCTAssertNil(reading.connected)
        XCTAssertNil(reading.battery)
        XCTAssertTrue(transport.routeWrites.isEmpty)
        transport.rejectLink = false
        transport.route = 1
        let unsafe = BarracudaX2022Session(transport: transport).read()
        XCTAssertNotNil(unsafe.error)
        XCTAssertTrue(transport.routeWrites.isEmpty)
    }

    func testMissingHeadsetTransportDoesNotSelectRoute() {
        let transport = FakeTransport()
        transport.transportStatus = 0
        XCTAssertNil(BarracudaX2022Session(transport: transport).read().battery)
        XCTAssertTrue(transport.routeWrites.isEmpty)
    }

    func testUnknownConnectionIsNotDisplayedAsConfirmedDisconnection() {
        let reading = BarracudaX2022Reading(error: "Query timed out")
        let status = reading.status(audioActive: true)
        XCTAssertNil(status.batteryPercent)
        XCTAssertNil(status.isCharging)
        XCTAssertFalse(status.connectionKnown)
        XCTAssertEqual(status.connection, .dongle)
        XCTAssertTrue(status.description.contains("Connected:   unknown"))
        XCTAssertTrue(StatusFormatter.connectionLine(status).contains("Unknown"))
        XCTAssertEqual(status.diagnosticMessage, "Query timed out")
        XCTAssertEqual(StatusFormatter.batteryLine(status), "Battery: Unknown")
        XCTAssertEqual(StatusFormatter.chargingLine(status), "Status: Unknown")
    }

    func testZeroBatteryAndUnknownCableSurviveStatusConversion() {
        let reading = BarracudaX2022Reading(connected: true, battery: 0)
        let status = reading.status(audioActive: false)
        XCTAssertEqual(status.batteryPercent, 0)
        XCTAssertNil(status.isCharging)
        XCTAssertEqual(StatusFormatter.menuBarTitle(status), "🎧 0%")
    }
}

// Complete PI frames from the wire format, independent of production builders.
private func report(family: UInt8, payload: [UInt8]) -> [UInt8] {
    let frame: [UInt8] = [0x50, 0x49, family, 0xEA, 0xC0, 0xE6, 5, 0,
                          UInt8(payload.count), 0] + payload
    return [1, 0x80, UInt8(frame.count)] + frame
}

private final class FakeTransport: BarracudaX2022Transport {
    var queued: [[UInt8]] = []
    var beforeAck: [[UInt8]] = []
    var link: UInt8 = 1
    var route: UInt8 = 0
    var transportStatus: UInt8 = 0x1B
    var battery: UInt8 = 61
    var cable: UInt8 = 0
    var rejectLink = false
    var silentBattery = false
    var silentRemoteSelection = false
    var failRestoration = false
    var routeWrites: [UInt8] = []
    var lastRouteRead: UInt8?

    func send(_ bytes: [UInt8]) throws {
        XCTAssertEqual(bytes.count, 64)
        let family = bytes[5], seq = bytes[6], cmd = bytes[8]
        if family == 8 {
            if cmd == 0x21 && silentBattery { return }
            queued.append(report(family: 8, payload: [cmd, 1, 1, cmd == 0x21 ? battery : cable]))
            return
        }
        if cmd == 0xE1 {
            let value = bytes[9]
            routeWrites.append(value)
            if value == 0 && failRestoration { return }
            route = value
            if value == 1 && silentRemoteSelection { return }
        }
        queued += beforeAck
        beforeAck = []
        queued.append(report(family: 1, payload: [family, seq | 0x80, cmd == 0xE3 && rejectLink ? 1 : 0]))
        if cmd == 0xE1 { return }
        let value = cmd == 0xE3 ? link : (cmd == 0xE6 ? transportStatus : route)
        if cmd == 0xE0 { lastRouteRead = route }
        queued.append(report(family: 0x0E, payload: [cmd, value]))
    }

    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        queued.isEmpty ? nil : queued.removeFirst()
    }
}
