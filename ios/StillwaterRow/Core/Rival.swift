import Foundation

/// A previous row, replayed second by second.
struct GhostTrack: Hashable {
    var samples: [Double]      // metres rowed at each whole second
    var duration: Double
    var distance: Double
    var complete: Bool
    var strokeRate: Double

    func distance(at t: Double) -> Double {
        if t >= duration { return distance }
        let i = Int(max(0, t))
        guard i + 1 < samples.count else { return samples.last ?? 0 }
        let f = t - Double(i)
        return samples[i] + (samples[i + 1] - samples[i]) * f
    }
}

enum Rival: Hashable {
    case paceBoat(split: Double)
    case target(split: Double)
    case ghost(GhostTrack, kind: RivalChoice)

    func distance(at t: Double, finish: Double?) -> Double {
        switch self {
        case .paceBoat(let split), .target(let split):
            let d = max(0, t) * 500 / split
            if let finish { return min(d, finish) }
            return d
        case .ghost(let track, _):
            return track.distance(at: t)
        }
    }

    /// Lower-case name used inside sentences.
    var name: String {
        switch self {
        case .paceBoat: return "the pace boat"
        case .target: return "the target time"
        case .ghost(_, let kind): return kind == .best ? "your best" : "your last session"
        }
    }

    var capitalizedName: String {
        let n = name
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    /// Shown in the HUD.
    var title: String {
        switch self {
        case .paceBoat(let split):
            return "Pace boat · \(Fmt.clock(split)) /500 m"
        case .target(let split):
            return "Target · \(Fmt.clock(split)) /500 m"
        case .ghost(let track, let kind):
            let what = track.complete ? Fmt.clock(track.duration, tenths: true) : "\(Fmt.meters(track.distance)) m"
            return (kind == .best ? "Your best · " : "Last session · ") + what
        }
    }

    /// Floating label above the boat.
    var tag: String {
        switch self {
        case .paceBoat(let split): return "PACE \(Fmt.clock(split))"
        case .target: return "TARGET"
        case .ghost(_, let kind): return kind == .best ? "BEST" : "LAST"
        }
    }

    var strokeRate: Double {
        switch self {
        case .paceBoat, .target: return 24
        case .ghost(let track, _): return track.strokeRate
        }
    }

    /// Time the rival needs for a distance piece, if it ever finished it.
    func finishTime(for target: Double) -> Double? {
        switch self {
        case .paceBoat(let split), .target(let split): return target / 500 * split
        case .ghost(let track, _): return track.complete ? track.duration : nil
        }
    }
}

/// A saved row in a plain value form, so game logic doesn't depend on SwiftData.
struct PastRow {
    let pieceID: String
    let date: Date
    let duration: Double
    let distance: Double
    let complete: Bool
    let samples: [Double]
    let strokes: Int
    var averageWorkSplit: Double? = nil
    var score: Int = 0

    var strokeRate: Double { duration > 0 ? Double(strokes) / (duration / 60) : 24 }
    var split: Double { distance > 0 ? duration / (distance / 500) : 0 }

    var track: GhostTrack {
        GhostTrack(samples: samples, duration: duration, distance: distance, complete: complete, strokeRate: strokeRate)
    }
}

enum Records {
    /// Best result for a piece: fastest finish for distances, furthest for the rest.
    static func best(for piece: Piece, in rows: [PastRow]) -> PastRow? {
        let list = rows.filter { $0.pieceID == piece.id }
        if piece.intervalSteps != nil {
            return list.filter { $0.complete && $0.averageWorkSplit != nil }.min { $0.averageWorkSplit! < $1.averageWorkSplit! }
        }
        if piece.isDistance {
            return list.filter(\.complete).min { $0.duration < $1.duration }
        }
        return list.max { $0.distance < $1.distance }
    }

    static func last(for piece: Piece, in rows: [PastRow]) -> PastRow? {
        rows.filter { $0.pieceID == piece.id }.max { $0.date < $1.date }
    }

    /// Average split of your three most recent rows of 300 m or more.
    static func recentSplit(_ rows: [PastRow]) -> Double? {
        let recent = rows.filter { $0.distance >= 300 }.sorted { $0.date > $1.date }.prefix(3)
        guard !recent.isEmpty else { return nil }
        return (recent.map(\.split).reduce(0, +) / Double(recent.count)).rounded()
    }

    /// Resolves who you race. Falls back to a pace boat when there is no ghost yet.
    static func rival(for piece: Piece, choice: RivalChoice, paceSplit: Double, rows: [PastRow]) -> (rival: Rival, fellBack: Bool) {
        switch choice {
        case .pace:
            return (.paceBoat(split: paceSplit), false)
        case .fleet:
            return (.paceBoat(split: recentSplit(rows) ?? paceSplit), false)
        case .best, .last:
            let row = choice == .best ? best(for: piece, in: rows) : last(for: piece, in: rows)
            if let row { return (.ghost(row.track, kind: choice), false) }
            return (.paceBoat(split: recentSplit(rows) ?? paceSplit), true)
        }
    }
}
