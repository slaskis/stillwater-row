import Foundation
import SwiftData

/// A saved row. Also the source of ghosts and personal bests.
@Model
final class RowSession {
    var id: UUID = UUID()
    var date: Date = Date.now
    var pieceID: String = "open"
    var duration: Double = 0
    var distance: Double = 0
    var complete: Bool = false
    var strokes: Int = 0
    var samples: [Double] = []
    var splits: [Double] = []
    var averageWatts: Double = 0
    var healthWorkoutID: UUID? = nil
    var averageHeartRate: Double? = nil
    var maxHeartRate: Double? = nil
    var averageWorkSplit: Double? = nil
    var score: Int = 0

    init(result: RowResult) {
        date = result.start
        pieceID = result.piece.id
        duration = result.duration
        distance = result.distance
        complete = result.complete
        strokes = result.strokes
        samples = result.samples
        splits = result.splits
        averageWatts = result.averageWatts
        averageWorkSplit = result.averageWorkSplit
        score = result.score
    }

    var piece: Piece { Piece.with(id: pieceID) }
    var end: Date { date.addingTimeInterval(duration) }
    var averageSplit: Double { distance > 0 ? duration / (distance / 500) : .infinity }

    var past: PastRow {
        PastRow(pieceID: pieceID, date: date, duration: duration, distance: distance,
                complete: complete, samples: samples, strokes: strokes,
                averageWorkSplit: averageWorkSplit, score: score)
    }
}
