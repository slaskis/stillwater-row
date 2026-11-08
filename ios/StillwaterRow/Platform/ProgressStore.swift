import Foundation
import Observation

/// Levels, coins, milestones, streaks, journeys and medals, kept in UserDefaults as one JSON blob.
@MainActor @Observable
final class ProgressStore {
    private(set) var state: ProgressState
    private static let key = "progress.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(ProgressState.self, from: data) {
            state = saved
        } else {
            state = ProgressState()
        }
    }

    func update(_ change: (inout ProgressState) -> Void) {
        var s = state
        change(&s)
        guard s != state else { return }
        state = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var journey: Journey { Journey.with(id: state.journeyID) }

    func isUnlocked(_ id: String) -> Bool { state.unlocked[id] != nil }

    /// Returns true the first time a milestone is earned.
    @discardableResult
    func unlock(_ id: String) -> Bool {
        guard state.unlocked[id] == nil else { return false }
        update { $0.unlocked[id] = Date() }
        return true
    }

    var challengeDoneToday: Bool { state.challenges[DailyChallenge.dayKey()] == true }
}
