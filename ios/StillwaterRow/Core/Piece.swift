import Foundation

enum Goal: Hashable {
    case open
    case distance(Double)
    case time(Double)
}

/// A workout you can pick on the dock.
struct Piece: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let goal: Goal

    static let all: [Piece] = [
        Piece(id: "open", name: "Just Row", subtitle: "No finish line", goal: .open),
        Piece(id: "1k", name: "1,000 m", subtitle: "Short and sharp", goal: .distance(1000)),
        Piece(id: "2k", name: "2,000 m", subtitle: "The classic test", goal: .distance(2000)),
        Piece(id: "5k", name: "5,000 m", subtitle: "Steady state", goal: .distance(5000)),
        Piece(id: "20min", name: "20 minutes", subtitle: "Hold your split", goal: .time(1200)),
    ]

    static func with(id: String) -> Piece { all.first { $0.id == id } ?? all[2] }

    var finishDistance: Double? {
        if case .distance(let m) = goal { return m }
        return nil
    }

    var isDistance: Bool { finishDistance != nil }
}

/// Who the shadow boat in the next lane is.
enum RivalChoice: String, CaseIterable, Identifiable {
    case best, last, pace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Personal best"
        case .last: return "Last session"
        case .pace: return "Pace boat"
        }
    }
}
