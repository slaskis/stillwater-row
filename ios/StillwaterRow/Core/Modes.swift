import Foundation

// MARK: - Fleet racing

struct Crew: Hashable {
    let name: String
    let shirt: UInt32
    let hull: UInt32
    let blade: UInt32
}

struct FleetBoat {
    let crew: Crew
    let speed: Double
    let head: Double       // head start in metres (negative starts behind)
    let lane: Double
    let phase: Double
    let amp: Double        // how much it surges ahead and drops back
    let strokeRate: Double
}

/// Six crews spread out ahead to reel in, or a single named rival in a duel.
struct FleetRace {
    let boats: [FleetBoat]
    let finish: Double?
    let isDuel: Bool

    static let crews: [Crew] = [
        Crew(name: "Grey Heron", shirt: 0xd9483b, hull: 0x2b2b2b, blade: 0xd9483b),
        Crew(name: "Birch Point", shirt: 0x2f6fb5, hull: 0xf0e9d8, blade: 0x2f6fb5),
        Crew(name: "Old Mill", shirt: 0x2f8f5b, hull: 0xf2c14e, blade: 0x2f8f5b),
        Crew(name: "Lantern", shirt: 0xf2c14e, hull: 0x1d3557, blade: 0xf2c14e),
        Crew(name: "North Wind", shirt: 0x8e5ba8, hull: 0xf1f1f1, blade: 0x8e5ba8),
        Crew(name: "Ironside", shirt: 0x1f1f1f, hull: 0xe76f51, blade: 0xffffff),
    ]

    /// Crews rowing around `split`: the slower ones start further ahead so you catch them at different points.
    static func standard(split: Double, piece: Piece) -> FleetRace {
        let v0 = 500 / split
        let duration: Double
        switch piece.goal {
        case .distance(let m): duration = m / v0
        case .time(let s): duration = s
        default: duration = 900
        }
        let factors = [0.86, 0.9, 0.93, 0.96, 0.985, 1.035]
        let catchAt = [0.12, 0.27, 0.42, 0.58, 0.8, 0]
        let lanes = [2.7, 6.9, -7.3, 2.7, 6.9, -7.3]
        let boats = factors.indices.map { i -> FleetBoat in
            let f = factors[i]
            return FleetBoat(crew: crews[i], speed: v0 * f,
                             head: f < 1 ? catchAt[i] * duration * v0 * (1 - f) : -14,
                             lane: lanes[i], phase: Double(i) * 1.7, amp: 2.5, strokeRate: 24 + f * 4)
        }
        return FleetRace(boats: boats, finish: piece.finishDistance, isDuel: false)
    }

    static func duel(crew: Crew, split: Double, finish: Double?) -> FleetRace {
        FleetRace(boats: [FleetBoat(crew: crew, speed: 500 / split, head: 0, lane: 2.7, phase: 0, amp: 5, strokeRate: 26)],
                  finish: finish, isDuel: true)
    }

    var total: Int { boats.count + 1 }

    func distance(_ i: Int, at t: Double) -> Double {
        let b = boats[i]
        let d = b.head + b.speed * t + sin(t / 11 + b.phase) * b.amp
        if let finish { return min(d, finish) }
        return d
    }

    /// When boat `i` reaches `target`, including its surge, so results match what you saw on the water.
    func finishTime(_ i: Int, target: Double) -> Double {
        let b = boats[i]
        var t = (target - b.head) / b.speed
        for _ in 0..<12 { t = (target - b.head - sin(t / 11 + b.phase) * b.amp) / b.speed }
        return t
    }

    struct Standing: Equatable {
        let position: Int
        let nextName: String?
        let nextGap: Double      // metres to the boat ahead
        let behindGap: Double?   // metres to the boat behind
    }

    func standing(me: Double, at t: Double) -> Standing {
        var ahead = 0
        var next: (String, Double)?
        var behind: Double?
        for i in boats.indices {
            let g = distance(i, at: t) - me
            if g > 0 {
                ahead += 1
                if next == nil || g < next!.1 { next = (boats[i].crew.name, g) }
            } else if behind == nil || -g < behind! {
                behind = -g
            }
        }
        return Standing(position: ahead + 1, nextName: next?.0, nextGap: next?.1 ?? 0, behindGap: behind)
    }

    /// Final position: by finish time on a distance piece, otherwise by distance when you stop.
    func finalPosition(myTime: Double, myDistance: Double, completedDistance: Bool) -> Int {
        if completedDistance, let finish {
            return 1 + boats.indices.filter { finishTime($0, target: finish) < myTime }.count
        }
        return 1 + boats.indices.filter { distance($0, at: myTime) > myDistance }.count
    }
}

// MARK: - Outrun the storm

/// A squall that starts 80 m behind and keeps speeding up.
struct StormChase {
    private(set) var position: Double = -80
    let baseSpeed: Double

    init(split: Double) { baseSpeed = 500 / split }

    mutating func advance(dt: Double, t: Double) {
        let f = t < 240 ? 0.75 + 0.35 * t / 240 : 1.1 + 0.08 * (t - 240) / 60
        position += baseSpeed * f * dt
    }

    func gap(_ me: Double) -> Double { me - position }

    /// 0 = far behind, 3 = about to catch you.
    static func level(gap: Double) -> Int { gap < 20 ? 3 : gap < 50 ? 2 : gap < 100 ? 1 : 0 }

    /// How dark the sky is, 0…1.
    static func darkness(gap: Double) -> Double { clamp(1 - (gap - 20) / 160, 0, 1) }
}

// MARK: - Speed gates

struct SpeedGate: Identifiable, Equatable {
    enum State: Equatable { case waiting, live, hit(Int), miss }
    let id: Int
    let d: Double
    let gold: Bool
    var state: State = .waiting
    var target: Double = 0
    var t0: Double = 0
    var d0: Double = 0
}

/// Every 400 m a gate: beat the target split over the last 100 m. Hits in a row multiply the points.
struct GateCourse {
    enum Event: Equatable {
        case opened(SpeedGate)
        case hit(SpeedGate, split: Double, combo: Int)
        case missed(SpeedGate, split: Double)
    }

    static let window = 100.0
    private(set) var gates: [SpeedGate]
    private(set) var hits = 0
    private(set) var attempts = 0
    private(set) var combo = 0
    private(set) var bestCombo = 0

    init(piece: Piece) {
        let limit = piece.finishDistance.map { $0 - 150 } ?? 60_000
        var list: [SpeedGate] = []
        var d = 300.0
        while d <= limit {
            list.append(SpeedGate(id: list.count, d: d, gold: list.count % 4 == 3))
            d += 400
        }
        gates = list
    }

    var live: SpeedGate? { gates.first { $0.state == .live } }
    var next: SpeedGate? { gates.first { $0.state == .waiting } }

    func liveSplit(t: Double, d: Double) -> Double? {
        guard let g = live else { return nil }
        let dd = d - g.d0
        return dd > 3 ? 500 * (t - g.t0) / dd : nil
    }

    /// - baseSplit: what you've been rowing; targets are set a little faster.
    mutating func update(t: Double, d: Double, baseSplit: Double) -> [Event] {
        var events: [Event] = []
        for i in gates.indices {
            let ahead = gates[i].d - d
            if ahead > Self.window { break }
            if gates[i].state == .waiting {
                gates[i].state = .live
                gates[i].t0 = t
                gates[i].d0 = d
                gates[i].target = clamp((baseSplit - (gates[i].gold ? 6 : 2)).rounded(), 85, 300)
                events.append(.opened(gates[i]))
            }
            if gates[i].state == .live, ahead <= 0 {
                let dd = d - gates[i].d0
                let split = dd > 1 ? 500 * (t - gates[i].t0) / dd : 999
                attempts += 1
                if split <= gates[i].target + 0.05 {
                    hits += 1
                    combo += 1
                    bestCombo = max(bestCombo, combo)
                    let points = (gates[i].gold ? 100 : 40) * min(combo, 5)
                    gates[i].state = .hit(points)
                    events.append(.hit(gates[i], split: split, combo: combo))
                } else {
                    combo = 0
                    gates[i].state = .miss
                    events.append(.missed(gates[i], split: split))
                }
            }
        }
        return events
    }
}

// MARK: - Intervals

struct RepResult: Equatable {
    let split: Double
    let target: Double
    var hit: Bool { split <= target + 0.05 }
}

/// Steps through an interval workout and reports what the cox should call.
struct IntervalRunner {
    enum Event: Equatable {
        case workStarted(rep: Int, of: Int, target: Double, step: IntervalStep)
        case restStarted(seconds: Double, nextRep: Int)
        case halfway(onTarget: Bool)
        case lastHundred
        case lastTenSeconds
        case restEnding
        case restBeep
        case repDone(RepResult)
        case finished
    }

    let steps: [IntervalStep]
    let base: Double
    private(set) var index = 0
    private(set) var t0: Double = 0
    private(set) var d0: Double = 0
    private(set) var reps: [RepResult] = []
    private var begun = false
    private var flags: Set<String> = []

    init(steps: [IntervalStep], base: Double) {
        self.steps = steps
        self.base = base
    }

    var repCount: Int { steps.filter { $0.kind == .work }.count }
    var current: IntervalStep? { index < steps.count ? steps[index] : nil }
    var isFinished: Bool { index >= steps.count }
    /// Number of the current hard piece, or the last one during a rest.
    var repNumber: Int { steps.prefix(min(index + 1, steps.count)).filter { $0.kind == .work }.count }
    var averageWorkSplit: Double? { reps.isEmpty ? nil : reps.map(\.split).reduce(0, +) / Double(reps.count) }

    func target(_ step: IntervalStep) -> Double { (base - step.offset).rounded() }

    func currentSplit(t: Double, d: Double) -> Double? {
        let dd = d - d0
        return dd > 5 ? 500 * (t - t0) / dd : nil
    }

    /// Overall progress through the workout, 0…1.
    func progress(t: Double, d: Double) -> Double {
        guard let step = current else { return 1 }
        let within: Double
        if let m = step.meters { within = (d - d0) / m } else { within = (t - t0) / max(1, step.seconds ?? 1) }
        return (Double(index) + clamp(within, 0, 1)) / Double(steps.count)
    }

    func remainingText(t: Double, d: Double) -> String {
        guard let step = current else { return "Workout done" }
        if step.kind == .rest { return "Easy · \(Fmt.clock(max(0, (step.seconds ?? 0) - (t - t0))))" }
        if let m = step.meters { return "\(Fmt.meters(max(0, m - (d - d0)))) m to go" }
        return "\(Fmt.clock(max(0, (step.seconds ?? 0) - (t - t0)))) left"
    }

    mutating func update(t: Double, d: Double) -> [Event] {
        var events: [Event] = []
        if !begun {
            begun = true
            events += start(t: t, d: d)
        }
        guard let step = current else { return events }
        let elapsed = t - t0, done = d - d0
        switch step.kind {
        case .work:
            if let m = step.meters {
                if m > 150, m - done <= 100, flag("100") { events.append(.lastHundred) }
                else if done >= m / 2, flag("half") { events.append(.halfway(onTarget: onTarget(step, elapsed, done))) }
                if done >= m { events += finishRep(step, elapsed: elapsed, done: done, t: t, d: d) }
            } else if let s = step.seconds {
                if s - elapsed <= 10, flag("10") { events.append(.lastTenSeconds) }
                else if s >= 90, elapsed >= s / 2, flag("half") { events.append(.halfway(onTarget: onTarget(step, elapsed, done))) }
                if elapsed >= s { events += finishRep(step, elapsed: elapsed, done: done, t: t, d: d) }
            }
        case .rest:
            let left = (step.seconds ?? 0) - elapsed
            if left <= 10, flag("10") { events.append(.restEnding) }
            let beep = Int(left.rounded(.up))
            if left > 0, beep <= 3, flag("b\(beep)") { events.append(.restBeep) }
            if left <= 0 { events += advance(t: t, d: d) }
        }
        return events
    }

    private mutating func flag(_ key: String) -> Bool {
        guard !flags.contains(key) else { return false }
        flags.insert(key)
        return true
    }

    private func onTarget(_ step: IntervalStep, _ elapsed: Double, _ done: Double) -> Bool {
        done > 5 && 500 * elapsed / done <= target(step)
    }

    private mutating func finishRep(_ step: IntervalStep, elapsed: Double, done: Double, t: Double, d: Double) -> [Event] {
        let result = RepResult(split: done > 1 ? 500 * elapsed / done : 999, target: target(step))
        reps.append(result)
        return [.repDone(result)] + advance(t: t, d: d)
    }

    private mutating func advance(t: Double, d: Double) -> [Event] {
        index += 1
        if index >= steps.count { return [.finished] }
        return start(t: t, d: d)
    }

    private mutating func start(t: Double, d: Double) -> [Event] {
        t0 = t
        d0 = d
        flags.removeAll()
        let s = steps[index]
        switch s.kind {
        case .work: return [.workStarted(rep: repNumber, of: repCount, target: target(s), step: s)]
        case .rest: return [.restStarted(seconds: s.seconds ?? 0, nextRep: repNumber + 1)]
        }
    }
}
