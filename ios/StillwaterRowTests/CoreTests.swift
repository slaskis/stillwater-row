import XCTest
@testable import StillwaterRow

final class FitShowTests: XCTestCase {
    /// Builds `02 <body…> <xor> 03` the way the console does.
    private func frame(_ body: [UInt8]) -> [UInt8] {
        [0x02] + body + [body.reduce(0, ^), 0x03]
    }

    func testPollFramesHaveValidChecksums() {
        for step in 0..<12 {
            let f = FitShow.pollFrame(step: step)
            XCTAssertEqual(f.first, 0x02)
            XCTAssertEqual(f.last, 0x03)
            XCTAssertEqual(f[1..<(f.count - 2)].reduce(0, ^), f[f.count - 2], "step \(step)")
        }
    }

    func testDecodesTotals() {
        // 0x43 0x01, distance 1234 m at bytes 5–6, 57 strokes at bytes 9–10.
        let f = frame([0x43, 0x01, 0x00, 0x00, 0xD2, 0x04, 0x00, 0x00, 0x39, 0x00])
        XCTAssertEqual(f.count, 13)
        var decoder = FitShowDecoder()
        XCTAssertEqual(decoder.feed(f), [RowerSample(distance: 1234, strokes: 57)])
    }

    func testDistanceFlagMultipliesByTen() {
        let f = frame([0x43, 0x01, 0x00, 0x00, 0x2C, 0x81, 0x00, 0x00, 0x10, 0x00])   // 0x812C -> 300 × 10
        XCTAssertEqual(FitShow.decode(f)?.distance, 3000)
    }

    func testDecodesStatusWhileRunning() {
        // running flag 0x02, stroke rate 26 at bytes 6–7, power 1450 (/10) at bytes 9–10.
        let f = frame([0x42, 0x02, 0x00, 0x00, 0x00, 0x1A, 0x00, 0x00, 0xAA, 0x05, 0x00, 0x00])
        XCTAssertEqual(f.count, 15)
        XCTAssertEqual(FitShow.decode(f), RowerSample(strokeRate: 26, power: 145))
    }

    func testReassemblesSplitAndJoinedNotifications() {
        let a = frame([0x43, 0x01, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x05, 0x00])
        let b = frame([0x43, 0x01, 0x00, 0x00, 0xC8, 0x00, 0x00, 0x00, 0x0A, 0x00])
        var decoder = FitShowDecoder()
        XCTAssertTrue(decoder.feed(Array(a.prefix(6))).isEmpty)
        let out = decoder.feed(Array(a.dropFirst(6)) + [0xFF] + b)
        XCTAssertEqual(out.map(\.distance), [100, 200])
    }
}

final class ProtocolTests: XCTestCase {
    func testFTMSRowerData() {
        // flags: distance (4) + instantaneous pace (8) + power (32); stroke fields present (bit 0 clear)
        let bytes: [UInt8] = [0x2C, 0x00, 0x34, 0x2A, 0x00, 0xE8, 0x03, 0x00, 0x7D, 0x00, 0x96, 0x00]
        let s = FTMS.decodeRowerData(bytes)
        XCTAssertEqual(s?.strokeRate, 26)
        XCTAssertEqual(s?.strokes, 42)
        XCTAssertEqual(s?.distance, 1000)
        XCTAssertEqual(s?.pace, 125)
        XCTAssertEqual(s?.power, 150)
    }

    func testHeartRate() {
        XCTAssertEqual(HeartRateMeasurement.decode([0x00, 0x8C]), 140)
        XCTAssertEqual(HeartRateMeasurement.decode([0x01, 0x2C, 0x01]), 300)
    }

    func testConsoleTrackerSurvivesReset() {
        var t = ConsoleTracker()
        t.update(raw: 400, at: 0)
        t.update(raw: 420, at: 2)
        t.update(raw: 3, at: 3)          // console reset
        XCTAssertEqual(t.total, 423)
    }
}

final class PhysicsTests: XCTestCase {
    func testTwentyFourStrokesAMinuteIsAboutTwoOhFive() {
        var p = RowPhysics()
        let dt = 1.0 / 60
        var t = 0.0, next = 0.0, d60 = 0.0
        while t < 120 {
            if t >= next { p.tapStroke(); next += 60.0 / 24 }
            p.stepTap(dt: dt)
            t += dt
            if abs(t - 60) < dt / 2 { d60 = p.d }
        }
        let split = 500 * 60 / (p.d - d60)
        XCTAssertEqual(split, 125, accuracy: 4)
    }

    func testBoatGlidesWhenStrokesStop() {
        var p = RowPhysics()
        p.v = 4
        for _ in 0..<120 { p.stepDevice(dt: 1.0 / 60, consoleDistance: 0, targetSpeed: 0, rowing: false, surge: 1) }
        XCTAssertGreaterThan(p.v, 3, "should still be gliding after 2 s")
        XCTAssertGreaterThan(p.d, 6)
    }
}

final class FormatAndRivalTests: XCTestCase {
    func testFormatting() {
        XCTAssertEqual(Fmt.clock(125.34, tenths: true), "2:05.3")
        XCTAssertEqual(Fmt.clock(119.96, tenths: true), "2:00.0")
        XCTAssertEqual(Fmt.split(.infinity), "–:––")
        XCTAssertEqual(Fmt.meters(2000), "2,000")
        XCTAssertEqual(Fmt.marker(1250), "1.25 km")
        XCTAssertEqual(Fmt.spokenSplit(125), "2 oh 5")
    }

    func testGhostInterpolates() {
        let g = GhostTrack(samples: [0, 4, 8, 12], duration: 3, distance: 12, complete: true, strokeRate: 24)
        XCTAssertEqual(g.distance(at: 1.5), 6, accuracy: 0.001)
        XCTAssertEqual(g.distance(at: 10), 12)
    }

    func testRivalFallsBackToPaceBoat() {
        let r = Records.rival(for: Piece.with(id: "2k"), choice: .best, paceSplit: 130, rows: [])
        XCTAssertTrue(r.fellBack)
        XCTAssertEqual(r.rival, .paceBoat(split: 130))
    }

    func testSplitsAreRecorded() {
        var e = SessionEngine(piece: Piece.with(id: "1k"))
        e.stroke(at: 0)
        var d = 0.0
        var segments: [Double] = []
        for _ in 0..<(130 * 60) {
            d += 4.0 / 60
            segments += e.advance(dt: 1.0 / 60, distance: d, watts: 180)
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0], 125, accuracy: 0.1)
        XCTAssertFalse(e.isComplete(distance: d))
    }
}
