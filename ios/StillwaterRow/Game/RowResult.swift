import Foundation

struct XPGain: Equatable {
    let gain: Int
    let before: Int
    let after: Int
    var levelBefore: Int { Levels.level(xp: before) }
    var levelAfter: Int { Levels.level(xp: after) }
    var leveledUp: Bool { levelAfter > levelBefore }
}

struct JourneyLine: Equatable {
    let journey: Journey
    let before: Double
    let after: Double
    let reached: [String]

    var next: JourneyStop? { journey.nextStop(after: after) }
    var complete: Bool { after >= journey.meters }
}

/// A finished row, as shown on the results screen.
struct RowResult: Identifiable {
    enum HealthState: Equatable {
        case off, saving, saved
        case failed(String)
    }

    let id = UUID()
    let piece: Piece
    let start: Date
    let end: Date
    let duration: Double
    let distance: Double
    let complete: Bool
    let strokes: Int
    let averageWatts: Double
    let splits: [Double]
    let samples: [Double]
    let saveable: Bool
    var verdict: String? = nil
    var verdictGood = true
    var recordLine: String? = nil
    var health: HealthState = .off
    var heartRate: HeartRateSummary? = nil

    var score = 0
    var xp: XPGain? = nil
    var newAchievements: [Achievement] = []
    var event: EventOutcome? = nil
    var journey: JourneyLine? = nil
    var reps: [RepResult] = []
    var challengeText: String? = nil
    var challengeDone = false
    var gatesHit = 0
    var gatesTried = 0
    var bestCombo = 0
    var caughtByStorm = false
    var spotted: [Animal] = []

    var averageSplit: Double { distance > 0 ? duration / (distance / 500) : .infinity }
    var averageRate: Double { duration > 0 ? Double(strokes) / (duration / 60) : 0 }
    var averageWorkSplit: Double? { reps.isEmpty ? nil : reps.map(\.split).reduce(0, +) / Double(reps.count) }
    /// Active energy, from Concept2's rule of thumb: 4 kcal per hour per watt.
    var energy: Double { averageWatts * duration / 900 }

    var title: String {
        switch piece.goal {
        case .distance where complete: return "\(piece.name) in \(Fmt.clock(duration, tenths: true))"
        case .time where complete: return "\(Fmt.meters(distance)) m in \(piece.name)"
        case .intervals where complete: return "\(piece.name) done"
        case .storm: return "\(Fmt.meters(distance)) m before the storm"
        default: return "\(Fmt.meters(distance)) m in \(Fmt.clock(duration))"
        }
    }

    /// Worth a celebration on the results screen.
    var isCelebration: Bool {
        (complete && !piece.isStorm) || (xp?.leveledUp ?? false) || (recordLine?.hasPrefix("New") ?? false) || (event?.improved ?? false)
    }
}
