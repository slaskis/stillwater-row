import Foundation

/// Works out who you race and what's on the water, then starts the countdown.
@MainActor
enum Launcher {
    struct Prefs {
        var choice: RivalChoice
        var pace: Double
        var gates: Bool
        var condition: String = "auto"   // a Condition raw value, or "auto"
        var scenery: String = "auto"     // a Scenery raw value, or "auto"

        /// The dock's settings, as saved by its @AppStorage controls.
        static var current: Prefs {
            let d = UserDefaults.standard
            return Prefs(choice: RivalChoice(rawValue: d.string(forKey: "rival") ?? "") ?? .best,
                         pace: d.object(forKey: "paceSplit") as? Double ?? 130,
                         gates: d.object(forKey: "gates") as? Bool ?? true,
                         condition: d.string(forKey: "condition") ?? "auto",
                         scenery: d.string(forKey: "scenery") ?? "auto")
        }

        /// Auto follows the clock; auto scenery follows the journey you're on.
        func resolvedCondition() -> Condition {
            // The chance of rain is rolled once a day, so the dock doesn't flicker between day and rain.
            let roll = Double(DailyChallenge.hash(DailyChallenge.dayKey() + "rain") % 1000) / 1000
            return Condition(rawValue: condition) ?? Condition.auto(random: roll)
        }

        func resolvedScenery(journey: String) -> Scenery {
            Scenery(rawValue: scenery) ?? (journey == "skargard" ? .archipelago : .river)
        }
    }

    static func setup(_ piece: Piece, event: SeasonEvent? = nil, sessions: [RowSession], prefs: Prefs, progress: ProgressStore) -> RowSetup {
        let rows = sessions.map(\.past)
        let recent = Records.recentSplit(rows)
        let base = recent ?? 150
        var s = RowSetup(piece: piece, history: rows, event: event, baseSplit: base)
        if let event {
            s.condition = Condition(rawValue: event.condition) ?? .day
            s.scenery = Scenery.forEvent(event.id)
        } else {
            s.condition = prefs.resolvedCondition()
            s.scenery = prefs.resolvedScenery(journey: progress.state.journeyID)
        }

        if let event {
            switch event.kind {
            case .duel(_, let crew, let delta, _):
                s.opponent = .fleet(.duel(crew: crew, split: base + delta, finish: piece.finishDistance))
            case .timeTrial(let delta):
                s.opponent = .rival(.target(split: base + delta))
            case .fleet(let delta):
                s.opponent = .fleet(.standard(split: base + delta, piece: piece))
            case .gates:
                s.opponent = .rival(.paceBoat(split: base + 3))
                s.gates = true
            case .storm:
                s.opponent = .storm(StormChase(split: base))
            case .intervals:
                s.opponent = .none
            }
        } else if piece.isStorm {
            s.opponent = .storm(StormChase(split: base))
        } else if piece.intervalSteps != nil {
            s.opponent = .none
        } else if prefs.choice == .fleet {
            s.opponent = .fleet(.standard(split: recent ?? prefs.pace, piece: piece))
            s.gates = prefs.gates
        } else {
            s.opponent = .rival(Records.rival(for: piece, choice: prefs.choice, paceSplit: prefs.pace, rows: rows).rival)
            s.gates = prefs.gates
        }
        if piece.isStorm && event == nil { s.gates = prefs.gates }

        if !progress.challengeDoneToday {
            let today = Calendar.current.startOfDay(for: Date())
            s.challenge = DailyChallenge.today(recentSplit: Records.recentSplit(rows.filter { $0.date < today }))
        }
        let j = progress.journey
        if progress.state.journeyMeters(j) < j.meters { s.journey = j }
        return s
    }

    static func start(_ piece: Piece, event: SeasonEvent? = nil, sessions: [RowSession], prefs: Prefs, progress: ProgressStore, game: RowGame) {
        game.start(setup(piece, event: event, sessions: sessions, prefs: prefs, progress: progress))
    }
}
