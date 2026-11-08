import Foundation

/// The clock, strokes, splits and per-second trace of one row.
struct SessionEngine {
    let piece: Piece
    private(set) var t: Double = 0
    private(set) var started = false
    private(set) var startDate: Date?
    private(set) var strokes = 0
    private(set) var samples: [Double] = [0]
    private(set) var splits: [Double] = []
    private var next500: Double = 500
    private var strokeTimes: [Double] = []
    private var powerSum: Double = 0
    private var powerTime: Double = 0

    init(piece: Piece) { self.piece = piece }

    /// The clock starts on the first stroke.
    mutating func stroke(at now: Double) {
        if !started {
            started = true
            startDate = Date()
        }
        strokes += 1
        strokeTimes.append(now)
        if strokeTimes.count > 6 { strokeTimes.removeFirst() }
    }

    func strokeRate(now: Double) -> Double {
        guard strokeTimes.count >= 2, let last = strokeTimes.last, now - last <= 6 else { return 0 }
        let span = last - strokeTimes[0]
        return span > 0 ? 60 * Double(strokeTimes.count - 1) / span : 0
    }

    /// Advances the clock. Returns the time for each 500 m segment completed this frame.
    mutating func advance(dt: Double, distance: Double, watts: Double) -> [Double] {
        guard started else { return [] }
        t += dt
        powerSum += watts * dt
        powerTime += dt
        while Double(samples.count) <= t { samples.append(distance) }
        var completed: [Double] = []
        while distance >= next500 {
            let segment = t - splits.reduce(0, +)
            splits.append((segment * 10).rounded() / 10)
            completed.append(segment)
            next500 += 500
        }
        return completed
    }

    var averageWatts: Double { powerTime > 0 ? powerSum / powerTime : 0 }

    func isComplete(distance: Double) -> Bool {
        switch piece.goal {
        case .distance(let m): return distance >= m
        case .time(let s): return t >= s
        case .open, .storm, .intervals: return false
        }
    }

    func progress(distance: Double) -> Double {
        switch piece.goal {
        case .distance(let m): return clamp(distance / m, 0, 1)
        case .time(let s): return clamp(t / s, 0, 1)
        case .storm, .intervals: return 0
        case .open: return distance.truncatingRemainder(dividingBy: 500) / 500
        }
    }

    func progressText(distance: Double, connected: Bool) -> String {
        guard started else { return connected ? "Row when ready" : "Take your first stroke" }
        switch piece.goal {
        case .distance(let m):
            return "\(Fmt.meters(max(0, m - distance))) m to go"
        case .time(let s):
            return "\(Fmt.clock(max(0, s - t))) left"
        case .storm:
            return "Survived \(Fmt.clock(t))"
        case .intervals:
            return ""
        case .open:
            let next = (floor(distance / 500) + 1) * 500
            return "\(Fmt.meters(next - distance)) m to \(Fmt.marker(Int(next)))"
        }
    }
}
