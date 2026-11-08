import Foundation

/// The regatta season: eight events in a row, each unlocked by a medal in the one before.
struct SeasonEvent: Identifiable, Hashable {
    enum Kind: Hashable {
        case duel(rival: String, crew: Crew, delta: Double, taunts: Taunts)
        case timeTrial(delta: Double)
        case fleet(delta: Double)
        case gates
        case storm
        case intervals
    }

    struct Taunts: Hashable {
        let start: String
        let ahead: [String]     // said when they pass you
        let behind: [String]    // said when you pass them
        let win: String         // they win
        let lose: String        // you win
    }

    let id: String
    let name: String
    let place: String
    let goalText: String
    let kind: Kind
    let piece: Piece
    /// Thresholds for bronze, silver and gold (seconds of margin, gates, minutes or reps).
    let stars: [Double]
    let condition: String

    var number: Int { (Season.events.firstIndex(of: self) ?? 0) + 1 }

    var taunts: Taunts? {
        if case .duel(_, _, _, let t) = kind { return t }
        return nil
    }
}

struct EventOutcome: Equatable {
    let event: SeasonEvent
    let stars: Int
    let previous: Int
    let hint: String?
    let unlockedNext: SeasonEvent?

    var medal: String { ["No medal this time", "Bronze", "Silver", "Gold"][stars] }
    var improved: Bool { stars > previous }
}

enum Season {
    private static let svensson = SeasonEvent.Taunts(
        start: "Thirty years unbeaten, young one. Don't get your hopes up!",
        ahead: ["See you at the jetty!", "Is that all you have got?"],
        behind: ["Hmph. Beginner's luck.", "Not so fast, young one!"],
        win: "Thirty-one years! Better luck next summer.",
        lose: "Well rowed. I will get you next year.")

    private static let ingrid = SeasonEvent.Taunts(
        start: "Nice boat. Shame about the engine.",
        ahead: ["Bye for now!", "Keep up if you can!"],
        behind: ["Enjoy the view while it lasts.", "Oh, you want a race? Fine."],
        win: "That is my title, thank you very much.",
        lose: "Okay. You earned that one.")

    private static func piece(_ id: String, _ name: String, _ place: String, _ goal: Goal) -> Piece {
        Piece(id: id, name: name, subtitle: place, goal: goal, hidden: true)
    }

    static let events: [SeasonEvent] = [
        SeasonEvent(id: "ev1", name: "Village Sprint", place: "Söderköping", goalText: "Beat Svensson over 500 m",
                    kind: .duel(rival: "Old Man Svensson", crew: Crew(name: "Old Man Svensson", shirt: 0x6b4f2a, hull: 0xd9c7a3, blade: 0x6b4f2a), delta: 8, taunts: svensson),
                    piece: piece("ev1", "Village Sprint", "Söderköping", .distance(500)), stars: [0, 3, 8], condition: "dawn"),
        SeasonEvent(id: "ev2", name: "Canal Time Trial", place: "Göta kanal", goalText: "Beat the target time over 1,000 m",
                    kind: .timeTrial(delta: 2), piece: piece("ev2", "Canal Time Trial", "Göta kanal", .distance(1000)), stars: [0, 3, 6], condition: "day"),
        SeasonEvent(id: "ev3", name: "Lantern Race", place: "Motala", goalText: "Finish in the top 3 of 7",
                    kind: .fleet(delta: 6), piece: piece("ev3", "Lantern Race", "Motala", .distance(1000)), stars: [], condition: "night"),
        SeasonEvent(id: "ev4", name: "Gate Run", place: "Lake Roxen", goalText: "Clear three speed gates over 1,500 m",
                    kind: .gates, piece: piece("ev4", "Gate Run", "Lake Roxen", .distance(1500)), stars: [1, 2, 3], condition: "sunset"),
        SeasonEvent(id: "ev5", name: "Storm Warning", place: "Lake Vättern", goalText: "Stay ahead of the squall",
                    kind: .storm, piece: piece("ev5", "Storm Warning", "Lake Vättern", .storm), stars: [3, 5, 7], condition: "day"),
        SeasonEvent(id: "ev6", name: "Archipelago Classic", place: "Sandhamn", goalText: "Beat Ingrid over 2,000 m",
                    kind: .duel(rival: "Ingrid Holm", crew: Crew(name: "Ingrid Holm", shirt: 0x1f6f8b, hull: 0xf4f1ea, blade: 0xe85d4a), delta: -1, taunts: ingrid),
                    piece: piece("ev6", "Archipelago Classic", "Sandhamn", .distance(2000)), stars: [0, 3, 6], condition: "sunset"),
        SeasonEvent(id: "ev7", name: "Interval Gauntlet", place: "Vaxholm", goalText: "Hit the target on four hard 500s",
                    kind: .intervals, piece: piece("ev7", "Interval Gauntlet", "Vaxholm", .intervals(Piece.fourBy500)), stars: [2, 3, 4], condition: "rain"),
        SeasonEvent(id: "ev8", name: "Head of the River", place: "Stockholm", goalText: "Win against the six best crews",
                    kind: .fleet(delta: -3), piece: piece("ev8", "Head of the River", "Stockholm", .distance(2000)), stars: [], condition: "dawn"),
    ]

    static func event(id: String) -> SeasonEvent? { events.first { $0.id == id } }

    static func isUnlocked(_ index: Int, stars: [String: Int]) -> Bool {
        index == 0 || (stars[events[index - 1].id] ?? 0) > 0
    }

    struct Performance {
        var complete: Bool
        var margin: Double?          // seconds ahead of the rival or target at the finish
        var fleetPosition: Int?
        var gatesHit: Int
        var minutes: Double
        var repsHit: Int
    }

    /// Medals for one attempt, with a hint for the next one.
    static func outcome(_ ev: SeasonEvent, _ p: Performance, previous: Int, stars: [String: Int]) -> EventOutcome {
        let medals = ["bronze", "silver", "gold"]
        func tier(_ v: Double) -> Int { v >= ev.stars[2] ? 3 : v >= ev.stars[1] ? 2 : v >= ev.stars[0] ? 1 : 0 }
        func count(_ n: Double, _ word: String) -> String { "\(Int(n)) \(word)\(n == 1 ? "" : "s")" }
        var s = 0
        var hint: String?
        switch ev.kind {
        case .duel, .timeTrial:
            let m = p.complete ? (p.margin ?? -1) : -1
            s = m > ev.stars[2] ? 3 : m > ev.stars[1] ? 2 : m > ev.stars[0] ? 1 : 0
            if s == 0 {
                if case .duel = ev.kind { hint = "Win the race for bronze." } else { hint = "Beat the target time for bronze." }
            } else if s < 3 {
                hint = "Win by more than \(Int(ev.stars[s])) s for \(medals[s])."
            }
        case .fleet:
            let pos = p.complete ? (p.fleetPosition ?? 9) : 9
            s = pos == 1 ? 3 : pos == 2 ? 2 : pos == 3 ? 1 : 0
            if s == 0 { hint = "Finish in the top 3 for bronze." } else if s < 3 { hint = "Finish \(s == 1 ? "2nd" : "1st") for \(medals[s])." }
        case .gates:
            s = p.complete ? tier(Double(p.gatesHit)) : 0
            if s < 3 { hint = "Clear \(count(ev.stars[s], "gate")) for \(medals[s])." }
        case .storm:
            s = tier(p.minutes)
            if s < 3 { hint = "Survive \(Int(ev.stars[s])) minutes for \(medals[s])." }
        case .intervals:
            s = p.complete ? tier(Double(p.repsHit)) : 0
            if s < 3 { hint = "Hit \(Int(ev.stars[s])) rep targets for \(medals[s])." }
        }
        let i = events.firstIndex(of: ev) ?? 0
        let next = previous == 0 && s > 0 && i < events.count - 1 ? events[i + 1] : nil
        return EventOutcome(event: ev, stars: s, previous: previous, hint: hint, unlockedNext: next)
    }
}

// MARK: - Journeys

struct JourneyStop: Hashable {
    let name: String
    let km: Double
    let fact: String
    var meters: Double { km * 1000 }
}

/// A long trip rowed a session at a time. Every metre you row counts towards it.
struct Journey: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let km: Double
    let stops: [JourneyStop]

    var meters: Double { km * 1000 }

    func nextStop(after m: Double) -> JourneyStop? { stops.first { $0.meters > m } }
    func lastStop(at m: Double) -> JourneyStop { stops.last { $0.meters <= m } ?? stops[0] }

    static let all: [Journey] = [
        Journey(id: "gota", name: "Göta kanal", subtitle: "Mem → Sjötorp", km: 190, stops: [
            JourneyStop(name: "Mem", km: 0, fact: "The canal's eastern end, where it meets the Baltic at Slätbaken."),
            JourneyStop(name: "Söderköping", km: 6, fact: "An old canal town a few kilometres in (distance approximate)."),
            JourneyStop(name: "Berg", km: 37, fact: "The Carl Johan staircase: seven locks in a row lifting boats up from Lake Roxen."),
            JourneyStop(name: "Motala", km: 92, fact: "Where the canal reaches Lake Vättern."),
            JourneyStop(name: "Karlsborg", km: 125, fact: "A fortress town on the far shore of Lake Vättern."),
            JourneyStop(name: "Lake Viken", km: 140, fact: "The canal's highest point, 91.7 m above sea level (distance approximate)."),
            JourneyStop(name: "Töreboda", km: 160, fact: "The largest of the canal harbours that grew up with the railway (distance approximate)."),
            JourneyStop(name: "Sjötorp", km: 190, fact: "The western end on Lake Vänern. 190 km and 58 locks behind you."),
        ]),
        Journey(id: "skargard", name: "Stockholm archipelago", subtitle: "Strömkajen → Sandhamn", km: 52, stops: [
            JourneyStop(name: "Strömkajen", km: 0, fact: "Where the archipelago boats leave from, in front of the Grand Hôtel."),
            JourneyStop(name: "Fjäderholmarna", km: 6, fact: "The first islands out of the city (distance approximate)."),
            JourneyStop(name: "Stavsnäs", km: 38, fact: "The mainland's eastern harbour, 7–8 nautical miles from Sandhamn."),
            JourneyStop(name: "Sandhamn", km: 52, fact: "About 28 nautical miles out from Stockholm. Time for a swim."),
        ]),
    ]

    static func with(id: String) -> Journey { all.first { $0.id == id } ?? all[0] }
}
