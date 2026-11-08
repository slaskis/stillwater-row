import Foundation

/// One step of an interval workout: a hard piece (by metres or seconds) or easy paddling.
struct IntervalStep: Hashable {
    enum Kind: Hashable { case work, rest }
    let kind: Kind
    var meters: Double? = nil
    var seconds: Double? = nil
    /// Hard pieces aim this many seconds per 500 m faster than your recent split.
    var offset: Double = 0

    static func work(meters: Double, offset: Double) -> IntervalStep { IntervalStep(kind: .work, meters: meters, offset: offset) }
    static func work(seconds: Double, offset: Double) -> IntervalStep { IntervalStep(kind: .work, seconds: seconds, offset: offset) }
    static func rest(_ seconds: Double) -> IntervalStep { IntervalStep(kind: .rest, seconds: seconds) }
}

enum Goal: Hashable {
    case open
    case distance(Double)
    case time(Double)
    case storm
    case intervals([IntervalStep])
}

/// A workout you can pick on the dock (or one of the regatta events).
struct Piece: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let goal: Goal
    var hidden = false

    static let fourBy500: [IntervalStep] = [
        .work(meters: 500, offset: 4), .rest(90), .work(meters: 500, offset: 4), .rest(90),
        .work(meters: 500, offset: 4), .rest(90), .work(meters: 500, offset: 4),
    ]

    static let pyramid: [IntervalStep] = [
        .work(seconds: 60, offset: 7), .rest(60), .work(seconds: 120, offset: 5), .rest(60),
        .work(seconds: 180, offset: 3), .rest(60), .work(seconds: 120, offset: 5), .rest(60),
        .work(seconds: 60, offset: 7),
    ]

    static let all: [Piece] = [
        Piece(id: "open", name: "Just Row", subtitle: "No finish line", goal: .open),
        Piece(id: "1k", name: "1,000 m", subtitle: "Short and sharp", goal: .distance(1000)),
        Piece(id: "2k", name: "2,000 m", subtitle: "The classic test", goal: .distance(2000)),
        Piece(id: "5k", name: "5,000 m", subtitle: "Steady state", goal: .distance(5000)),
        Piece(id: "20min", name: "20 minutes", subtitle: "Hold your split", goal: .time(1200)),
        Piece(id: "4x500", name: "4 × 500 m", subtitle: "Intervals, 1:30 easy between", goal: .intervals(fourBy500)),
        Piece(id: "pyramid", name: "Pyramid", subtitle: "1-2-3-2-1 min hard, 1 min easy", goal: .intervals(pyramid)),
        Piece(id: "storm", name: "Outrun the storm", subtitle: "Survive as long as you can", goal: .storm),
    ]

    static func with(id: String) -> Piece {
        all.first { $0.id == id } ?? Season.events.first { $0.piece.id == id }?.piece ?? all[2]
    }

    var finishDistance: Double? {
        if case .distance(let m) = goal { return m }
        return nil
    }

    var isDistance: Bool { finishDistance != nil }

    var intervalSteps: [IntervalStep]? {
        if case .intervals(let steps) = goal { return steps }
        return nil
    }

    var isStorm: Bool { goal == .storm }
}

/// Who you race in the other lanes.
enum RivalChoice: String, CaseIterable, Identifiable {
    case best, last, pace, fleet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Personal best"
        case .last: return "Last session"
        case .pace: return "Pace boat"
        case .fleet: return "The fleet"
        }
    }
}
