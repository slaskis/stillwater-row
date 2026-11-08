import XCTest
@testable import StillwaterRow

final class ModesTests: XCTestCase {
    func testFleetStartsSpreadAndFastestStartsBehind() {
        let f = FleetRace.standard(split: 125, piece: Piece.with(id: "2k"))
        XCTAssertEqual(f.boats.count, 6)
        XCTAssertEqual(f.total, 7)
        XCTAssertLessThan(f.boats[5].head, 0)
        XCTAssertGreaterThan(f.boats[0].head, 0)
        // Standing still at the start, everyone with a head start is ahead.
        XCTAssertEqual(f.standing(me: 0, at: 0).position, 6)
    }

    func testFleetFinishPositionUsesFinishTimes() {
        let f = FleetRace.duel(crew: FleetRace.crews[0], split: 120, finish: 500)
        let ft = f.finishTime(0, target: 500)
        XCTAssertEqual(f.distance(0, at: ft), 500, accuracy: 0.01)   // matches the boat on the water
        XCTAssertEqual(ft, 120, accuracy: 2)
        XCTAssertEqual(f.finalPosition(myTime: ft - 0.5, myDistance: 500, completedDistance: true), 1)
        XCTAssertEqual(f.finalPosition(myTime: ft + 0.5, myDistance: 500, completedDistance: true), 2)
    }

    func testStormSpeedsUpAndCatchesAStationaryBoat() {
        var s = StormChase(split: 150)
        var t = 0.0
        while s.gap(0) > 0 && t < 200 {
            s.advance(dt: 0.1, t: t)
            t += 0.1
        }
        // 80 m at 0.75 × 3.33 m/s ≈ 32 s
        XCTAssertEqual(t, 31, accuracy: 3)
        XCTAssertEqual(StormChase.level(gap: 10), 3)
        XCTAssertEqual(StormChase.level(gap: 150), 0)
    }

    func testGatesAreHitWhenFastEnough() {
        var g = GateCourse(piece: Piece.with(id: "2k"))
        XCTAssertEqual(g.gates.map(\.d), [300, 700, 1100, 1500])
        XCTAssertTrue(g.gates[3].gold)
        // Row at 4.2 m/s (≈1:59) against a base of 2:05 → target 2:03.
        var events: [GateCourse.Event] = []
        var t = 0.0, d = 0.0
        while d < 320 {
            t += 0.1
            d += 0.42
            events += g.update(t: t, d: d, baseSplit: 125)
        }
        XCTAssertEqual(g.hits, 1)
        XCTAssertEqual(g.combo, 1)
        guard case .hit(let gate, _, _)? = events.last else { return XCTFail("expected a hit") }
        XCTAssertEqual(gate.target, 123)
        XCTAssertEqual(gate.state, .hit(40))
    }

    func testIntervalsStepThroughWorkAndRest() {
        var r = IntervalRunner(steps: Piece.fourBy500, base: 130)
        XCTAssertEqual(r.repCount, 4)
        var t = 0.0, d = 0.0
        var all: [IntervalRunner.Event] = []
        // Row each 500 m at 2:00 and paddle the rests.
        while !r.isFinished && t < 2000 {
            t += 0.1
            d += r.current?.kind == .work ? 500.0 / 120 * 0.1 : 0.2
            all += r.update(t: t, d: d)
        }
        XCTAssertTrue(r.isFinished)
        XCTAssertEqual(r.reps.count, 4)
        XCTAssertTrue(r.reps.allSatisfy(\.hit))   // target 2:06
        XCTAssertEqual(all.last, .finished)
        XCTAssertEqual(r.averageWorkSplit ?? 0, 120, accuracy: 0.5)
    }

    func testLevels() {
        XCTAssertEqual(Levels.level(xp: 0), 1)
        XCTAssertEqual(Levels.level(xp: 499), 1)
        XCTAssertEqual(Levels.level(xp: 500), 2)
        XCTAssertEqual(Levels.rank(5), "Stroke seat")
    }

    func testDailyChallengeMatchesWebHash() {
        // FNV-1a of "a" is 0xe40c292c.
        XCTAssertEqual(DailyChallenge.hash("a"), 0xe40c292c)
        let c1 = DailyChallenge.today(Date(timeIntervalSince1970: 1_760_000_000), recentSplit: 130)
        let c2 = DailyChallenge.today(Date(timeIntervalSince1970: 1_760_000_000), recentSplit: 130)
        XCTAssertEqual(c1.text, c2.text)
    }

    func testSeasonMedals() {
        let ev = Season.events[0]
        let gold = Season.outcome(ev, .init(complete: true, margin: 9, fleetPosition: 1, gatesHit: 0, minutes: 2, repsHit: 0), previous: 0, stars: [:])
        XCTAssertEqual(gold.stars, 3)
        XCTAssertEqual(gold.unlockedNext?.id, "ev2")
        let none = Season.outcome(ev, .init(complete: true, margin: -2, fleetPosition: 2, gatesHit: 0, minutes: 2, repsHit: 0), previous: 0, stars: [:])
        XCTAssertEqual(none.stars, 0)
        XCTAssertNil(none.unlockedNext)
        XCTAssertTrue(Season.isUnlocked(0, stars: [:]))
        XCTAssertFalse(Season.isUnlocked(1, stars: [:]))
        XCTAssertTrue(Season.isUnlocked(1, stars: ["ev1": 1]))
    }

    func testStreak() {
        var p = ProgressState()
        let cal = Calendar.current
        let today = Date()
        for back in 0..<3 { p.markDay(cal.date(byAdding: .day, value: -back, to: today)!) }
        XCTAssertEqual(p.streak(today: today), 3)
    }

    func testHiddenEventPiecesResolve() {
        XCTAssertEqual(Piece.with(id: "ev6").finishDistance, 2000)
        XCTAssertFalse(Piece.all.contains { $0.hidden })
    }

    func testConditionFollowsTheClock() {
        let cal = Calendar.current
        func at(_ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: Date())! }
        XCTAssertEqual(Condition.auto(at(7)), .dawn)
        XCTAssertEqual(Condition.auto(at(12), random: 0.5), .day)
        XCTAssertEqual(Condition.auto(at(12), random: 0.1), .rain)
        XCTAssertEqual(Condition.auto(at(17)), .sunset)
        XCTAssertEqual(Condition.auto(at(22)), .night)
    }

    func testCosmeticsSubscriptAndOldSavesDecode() throws {
        var c = Cosmetics()
        c[.hat] = "crown"
        XCTAssertEqual(c.hat, "crown")
        c[.hat] = nil
        XCTAssertNil(c.hat)
        // A save from before the shop existed still loads.
        let old = #"{"xp":1200,"coins":40,"lifetime":5000,"unlocked":{},"days":[],"challenges":{},"journeys":{},"season":{},"journeyID":"gota"}"#
        let p = try JSONDecoder().decode(ProgressState.self, from: Data(old.utf8))
        XCTAssertEqual(p.xp, 1200)
        XCTAssertEqual(p.livery, "stillwater")
        XCTAssertTrue(p.owned.isEmpty)
    }
}
