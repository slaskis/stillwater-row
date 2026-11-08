import Foundation

// MARK: - Milestones

struct Achievement: Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let detail: String

    static let all: [Achievement] = [
        Achievement(id: "d100", code: "100", name: "First strokes", detail: "Row 100 m"),
        Achievement(id: "d500", code: "500", name: "Half a click", detail: "500 m in one go"),
        Achievement(id: "d1k", code: "1K", name: "The kilometre", detail: "1,000 m in one go"),
        Achievement(id: "d2k", code: "2K", name: "Race distance", detail: "2,000 m in one go"),
        Achievement(id: "d5k", code: "5K", name: "Long water", detail: "5,000 m in one go"),
        Achievement(id: "d10k", code: "10K", name: "Ten thousand", detail: "10,000 m in one go"),
        Achievement(id: "sub2", code: "1:59", name: "Under two", detail: "Hold sub-2:00 for 250 m"),
        Achievement(id: "rate30", code: "30", name: "Rate thirty", detail: "20 strokes at 30+ s/m"),
        Achievement(id: "ghost", code: "G", name: "Ghostbuster", detail: "Finish ahead of your rival"),
        Achievement(id: "pb", code: "PB", name: "New best", detail: "Beat a personal best"),
        Achievement(id: "streak3", code: "3D", name: "Three mornings", detail: "Row 3 days running"),
        Achievement(id: "life42", code: "42K", name: "River marathon", detail: "42,195 m in total"),
        Achievement(id: "fleet1", code: "1st", name: "Head of the river", detail: "Win a fleet race"),
        Achievement(id: "voyage", code: "J", name: "Voyager", detail: "Complete a whole journey"),
        Achievement(id: "storm5", code: "S5", name: "Weathered it", detail: "Outrun the storm for 5 minutes"),
        Achievement(id: "zone", code: "Z", name: "In the zone", detail: "Reach full rhythm flow"),
        Achievement(id: "season1", code: "S1", name: "Season champion", detail: "Earn a medal in every regatta event"),
        Achievement(id: "season3", code: "24", name: "Perfect season", detail: "Gold in every regatta event"),
        Achievement(id: "ivall", code: "IV", name: "Every rep", detail: "Hit the target on every interval"),
        Achievement(id: "combo5", code: "×5", name: "Five in a row", detail: "Hit 5 speed gates in a row"),
        Achievement(id: "p10", code: "P10", name: "Power ten", detail: "Find 8% extra speed in a Power 10"),
    ]

    static func with(id: String) -> Achievement? { all.first { $0.id == id } }

    static let distanceMilestones: [(Double, String)] = [(100, "d100"), (500, "d500"), (1000, "d1k"), (2000, "d2k"), (5000, "d5k"), (10000, "d10k")]
}

// MARK: - Levels

enum Levels {
    static func xp(for level: Int) -> Int { 250 * level * (level - 1) }

    static func level(xp: Int) -> Int {
        var l = 1
        while xp >= Self.xp(for: l + 1) { l += 1 }
        return l
    }

    static let ranks: [(Int, String)] = [(1, "Novice"), (3, "Club rower"), (5, "Stroke seat"), (8, "Captain"), (12, "Regatta finalist"), (16, "Olympian")]

    static func rank(_ level: Int) -> String { ranks.last { level >= $0.0 }?.1 ?? "Novice" }

    /// 0…1 through the current level.
    static func fraction(xp: Int) -> Double {
        let l = level(xp: xp), a = Self.xp(for: l), b = Self.xp(for: l + 1)
        return Double(xp - a) / Double(max(1, b - a))
    }
}

// MARK: - Daily challenge

struct ChallengeSnapshot {
    var distance: Double
    var time: Double
    var gatesHit: Int
    var bestCombo: Int
    var splits: [Double]
    var power10Best: Double
    var fleetPosition: Int?
    var storm: Bool
}

struct DailyChallenge {
    enum Need { case none, gates, fleet, storm }
    let text: String
    let need: Need
    let check: (ChallengeSnapshot, _ finished: Bool) -> Bool

    static func dayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// FNV-1a, the same hash the web version uses, so both pick the same challenge each day.
    static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for u in s.utf16 {
            h ^= UInt32(u)
            h = h &* 16777619
        }
        return h
    }

    /// - recentSplit: your average split before today, used to set a fair target.
    static func today(_ date: Date = Date(), recentSplit: Double?) -> DailyChallenge {
        let h = hash(dayKey(date) + "stillwater")
        let base = recentSplit ?? 150
        switch h % 8 {
        case 0:
            let n = [1500.0, 2000, 2500, 3000][Int((h >> 4) & 3)]
            return DailyChallenge(text: "Row \(Fmt.meters(n)) m in one session", need: .none) { s, _ in s.distance >= n }
        case 1:
            let n = 4 + Int((h >> 6) % 3)
            return DailyChallenge(text: "Clear \(n) speed gates in one session", need: .gates) { s, _ in s.gatesHit >= n }
        case 2:
            return DailyChallenge(text: "Hit 3 speed gates in a row", need: .gates) { s, _ in s.bestCombo >= 3 }
        case 3:
            let x = max(90, base - 4)
            return DailyChallenge(text: "Row a 500 m split under \(Fmt.clock(x))", need: .none) { s, _ in s.splits.contains { $0 <= x } }
        case 4:
            return DailyChallenge(text: "Find 5% extra speed in a Power 10", need: .none) { s, _ in s.power10Best >= 0.05 }
        case 5:
            let n = [10.0, 12, 15][Int((h >> 8) % 3)]
            return DailyChallenge(text: "Row for \(Int(n)) minutes in one session", need: .none) { s, _ in s.time >= n * 60 }
        case 6:
            return DailyChallenge(text: "Finish in the top 3 of a fleet race", need: .fleet) { s, fin in fin && (s.fleetPosition ?? 99) <= 3 }
        default:
            return DailyChallenge(text: "Outrun the storm for 1,000 m", need: .storm) { s, _ in s.storm && s.distance >= 1000 }
        }
    }
}

// MARK: - Saved progress

/// Everything the game remembers between rows apart from the rows themselves.
struct ProgressState: Codable, Equatable {
    var xp = 0
    var coins = 0
    var lifetime: Double = 0
    var unlocked: [String: Date] = [:]
    var days: [String] = []
    var challenges: [String: Bool] = [:]
    var journeys: [String: Double] = [:]
    var season: [String: Int] = [:]
    var journeyID = "gota"

    init() {}

    /// Missing keys fall back to defaults, so adding a field later never wipes saved progress.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        xp = try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0
        coins = try c.decodeIfPresent(Int.self, forKey: .coins) ?? 0
        lifetime = try c.decodeIfPresent(Double.self, forKey: .lifetime) ?? 0
        unlocked = try c.decodeIfPresent([String: Date].self, forKey: .unlocked) ?? [:]
        days = try c.decodeIfPresent([String].self, forKey: .days) ?? []
        challenges = try c.decodeIfPresent([String: Bool].self, forKey: .challenges) ?? [:]
        journeys = try c.decodeIfPresent([String: Double].self, forKey: .journeys) ?? [:]
        season = try c.decodeIfPresent([String: Int].self, forKey: .season) ?? [:]
        journeyID = try c.decodeIfPresent(String.self, forKey: .journeyID) ?? "gota"
    }

    var level: Int { Levels.level(xp: xp) }

    func journeyMeters(_ j: Journey) -> Double { min(journeys[j.id] ?? 0, j.meters) }

    /// Days in a row with a row, counting today or yesterday as the latest.
    func streak(today: Date = Date()) -> Int {
        let set = Set(days)
        let cal = Calendar.current
        var d = today
        if !set.contains(DailyChallenge.dayKey(d)) { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        var n = 0
        while set.contains(DailyChallenge.dayKey(d)) {
            n += 1
            d = cal.date(byAdding: .day, value: -1, to: d) ?? d
        }
        return n
    }

    var seasonStars: Int { Season.events.reduce(0) { $0 + (season[$1.id] ?? 0) } }

    mutating func markDay(_ date: Date = Date()) {
        let k = DailyChallenge.dayKey(date)
        if !days.contains(k) { days.append(k) }
        if days.count > 400 { days.removeFirst(days.count - 400) }
    }
}
