import Foundation
import HealthKit
import Observation

struct HeartRatePoint: Identifiable {
    let id = UUID()
    let seconds: Double     // since the start of the row
    let bpm: Double
}

struct HeartRateSummary {
    let average: Double
    let max: Double
    let points: [HeartRatePoint]
}

/// A rowing workout found in Apple Health, from this app or any other.
struct HealthWorkout: Identifiable {
    let id: UUID
    let start: Date
    let duration: Double
    let distance: Double?
    let energy: Double?
    let source: String
    let isOwn: Bool
}

/// Saves rows as indoor rowing workouts and reads rowing history and heart rate back.
@MainActor @Observable
final class HealthStore {
    let available = HKHealthStore.isHealthDataAvailable()
    var canSave = false
    var asked: Bool
    var saveRows: Bool { didSet { UserDefaults.standard.set(saveRows, forKey: "health.save") } }
    var history: [HealthWorkout] = []
    var lastError: String?

    @ObservationIgnored private let store = HKHealthStore()

    init() {
        asked = UserDefaults.standard.bool(forKey: "health.asked")
        saveRows = UserDefaults.standard.object(forKey: "health.save") as? Bool ?? true
        refreshStatus()
    }

    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKQuantityType(.distanceRowing), HKQuantityType(.activeEnergyBurned)]
    }

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.distanceRowing), HKQuantityType(.activeEnergyBurned)]
    }

    func refreshStatus() {
        guard available else { return }
        canSave = store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    func requestAccess() async {
        guard available else { return }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            asked = true
            UserDefaults.standard.set(true, forKey: "health.asked")
            refreshStatus()
            await loadHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves a finished row as an indoor rowing workout. Returns the workout's id.
    func save(_ row: RowResult) async throws -> UUID? {
        let config = HKWorkoutConfiguration()
        config.activityType = .rowing
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: row.start)

        var samples: [HKSample] = []
        let distanceType = HKQuantityType(.distanceRowing)
        // Distance in 10-second slices so Health can draw pace over time.
        var trace = Array(row.samples.prefix(Int(row.duration) + 1))
        trace.append(row.distance)
        var i = 0
        while i < trace.count - 1 {
            let j = min(i + 10, trace.count - 1)
            let metres = trace[j] - trace[i]
            let from = row.start.addingTimeInterval(Double(i))
            let to = row.start.addingTimeInterval(min(Double(j), row.duration))
            if metres > 0, to > from {
                samples.append(HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: metres), start: from, end: to))
            }
            i = j
        }
        if row.energy > 0 {
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: row.energy),
                                            start: row.start, end: row.end))
        }
        if !samples.isEmpty { try await builder.addSamples(samples) }
        try await builder.addMetadata([HKMetadataKeyIndoorWorkout: true, "StillwaterPiece": row.piece.name])
        try await builder.endCollection(at: row.end)
        let workout = try await builder.finishWorkout()
        return workout?.uuid
    }

    /// Heart rate recorded during a time window, by any source (a Withings watch after it syncs, a strap, …).
    func heartRate(from start: Date, to end: Date) async -> HeartRateSummary? {
        guard available else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
                                            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let results = try? await query.result(for: store), !results.isEmpty else { return nil }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let points = results.map { HeartRatePoint(seconds: $0.startDate.timeIntervalSince(start), bpm: $0.quantity.doubleValue(for: unit)) }
        let bpms = points.map(\.bpm)
        return HeartRateSummary(average: bpms.reduce(0, +) / Double(bpms.count), max: bpms.max() ?? 0, points: points)
    }

    /// Recent rowing workouts in Apple Health, including ones from other apps.
    func loadHistory() async {
        guard available, asked else { return }
        let query = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForWorkouts(with: .rowing))],
                                            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
                                            limit: 40)
        guard let workouts = try? await query.result(for: store) else { return }
        let ownID = Bundle.main.bundleIdentifier
        history = workouts.map { w in
            let distance = w.statistics(for: HKQuantityType(.distanceRowing))?.sumQuantity()?.doubleValue(for: .meter())
            let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            return HealthWorkout(id: w.uuid, start: w.startDate, duration: w.duration, distance: distance, energy: energy,
                                 source: w.sourceRevision.source.name,
                                 isOwn: w.sourceRevision.source.bundleIdentifier == ownID)
        }
    }
}
