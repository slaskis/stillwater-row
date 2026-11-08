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

    enum Purchase { case bought, equipped, removed, tooExpensive }

    /// Buys an item (and wears it), or toggles it on and off if you already own it.
    @discardableResult
    func shop(_ item: ShopItem) -> Purchase {
        if state.owned.contains(item.id) {
            let wearing = state.cosmetics[item.category] == item.id
            update { $0.cosmetics[item.category] = wearing ? nil : item.id }
            return wearing ? .removed : .equipped
        }
        guard state.coins >= item.price else { return .tooExpensive }
        update {
            $0.coins -= item.price
            $0.owned.append(item.id)
            $0.cosmetics[item.category] = item.id
        }
        return .bought
    }

    /// Next fact for a message in a bottle, cycling through them all.
    func nextFact() -> String {
        let i = ((state.factIndex ?? Int.random(in: 0..<Facts.all.count)) + 1) % Facts.all.count
        update { $0.factIndex = i }
        return Facts.all[i]
    }

    var challengeDoneToday: Bool { state.challenges[DailyChallenge.dayKey()] == true }
}
