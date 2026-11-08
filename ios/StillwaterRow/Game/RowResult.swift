import Foundation

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

    var averageSplit: Double { distance > 0 ? duration / (distance / 500) : .infinity }
    var averageRate: Double { duration > 0 ? Double(strokes) / (duration / 60) : 0 }
    /// Active energy, from Concept2's rule of thumb: 4 kcal per hour per watt.
    var energy: Double { averageWatts * duration / 900 }

    var title: String {
        switch piece.goal {
        case .distance where complete: return "\(piece.name) in \(Fmt.clock(duration, tenths: true))"
        case .time where complete: return "\(Fmt.meters(distance)) m in \(piece.name)"
        default: return "\(Fmt.meters(distance)) m in \(Fmt.clock(duration))"
        }
    }
}
