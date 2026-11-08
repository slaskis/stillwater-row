import Charts
import SwiftData
import SwiftUI

struct ResultsView: View {
    let result: RowResult
    @Environment(RowGame.self) private var game
    @Environment(HealthStore.self) private var health
    @Environment(ProgressStore.self) private var progress
    @State private var checkingHeartRate = false
    @Query(sort: \RowSession.date, order: .reverse) private var sessions: [RowSession]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Eyebrow(text: result.complete ? "Piece complete" : "Session ended")
                Text(result.title)
                    .font(.system(size: 40, weight: .bold).width(.condensed))
                    .monospacedDigit()

                if result.verdict != nil || result.recordLine != nil || !result.saveable {
                    VStack(alignment: .leading, spacing: 6) {
                        if let verdict = result.verdict {
                            Text(verdict).foregroundStyle(result.verdictGood ? Theme.good : Theme.bad)
                        }
                        if let record = result.recordLine { Text(record) }
                        if !result.saveable { Text("Too short to save.").foregroundStyle(Theme.dim) }
                    }
                    .font(.body.weight(.medium))
                }

                if let ev = result.event { EventResult(outcome: ev) }
                RewardsSection(result: result)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    tile(Fmt.split(result.averageSplit), "avg /500 m")
                    tile(String(format: "%.1f", result.averageRate), "avg s/m")
                    tile("\(Int(result.averageWatts.rounded()))", "avg watts")
                    tile("\(result.strokes)", "strokes")
                }

                heartRateSection

                if !result.reps.isEmpty { RepsSection(reps: result.reps) }

                Eyebrow(text: "Splits")
                if result.splits.isEmpty {
                    Text("Row a full 500 m to see your splits here.").font(.callout).foregroundStyle(Theme.dim)
                } else {
                    SplitChart(splits: result.splits).frame(height: 170)
                }

                healthLine

                HStack(spacing: 10) {
                    if let next = nextEvent {
                        Button("Next: \(next.name)") {
                            Launcher.start(next.piece, event: next, sessions: sessions, prefs: .current, progress: progress, game: game)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Button("Row it again") {
                        Launcher.start(result.piece, event: result.event?.event, sessions: sessions, prefs: .current, progress: progress, game: game)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Back to the dock") { game.backToDock() }
                        .buttonStyle(QuietButtonStyle())
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 640)
            .panel(24)
            .frame(maxWidth: .infinity)
            .padding()
            .padding(.top, 40)
        }
        .background(Color.black.opacity(0.35).ignoresSafeArea())
        .overlay { if result.isCelebration { ConfettiView(count: 220) } }
        .foregroundStyle(Theme.mist)
    }

    /// The next regatta event, once this one has earned a medal.
    private var nextEvent: SeasonEvent? {
        guard let ev = result.event?.event, let i = Season.events.firstIndex(of: ev), i + 1 < Season.events.count,
              Season.isUnlocked(i + 1, stars: progress.state.season) else { return nil }
        return Season.events[i + 1]
    }

    private func tile(_ value: String, _ label: String) -> some View {
        Stat(value: value, label: label, size: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var heartRateSection: some View {
        if let hr = result.heartRate {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Heart rate")
                HStack(spacing: 24) {
                    Stat(value: "\(Int(hr.average.rounded()))", label: "avg bpm", size: 26)
                    Stat(value: "\(Int(hr.max.rounded()))", label: "max bpm", size: 26)
                }
                if hr.points.count > 3 {
                    Chart(hr.points) { p in
                        LineMark(x: .value("Time", p.seconds), y: .value("BPM", p.bpm))
                            .foregroundStyle(Theme.bad)
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 90)
                }
            }
        } else if health.available, health.asked, result.saveable {
            HStack {
                Text("Heart rate appears once your watch has synced to Apple Health.")
                    .font(.callout)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Button(checkingHeartRate ? "Checking…" : "Check again") {
                    checkingHeartRate = true
                    Task {
                        await Recorder.refreshHeartRate(health: health, game: game)
                        checkingHeartRate = false
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(checkingHeartRate)
            }
        }
    }

    @ViewBuilder private var healthLine: some View {
        switch result.health {
        case .off: EmptyView()
        case .saving: Label("Saving to Apple Health…", systemImage: "heart.text.square").font(.footnote).foregroundStyle(Theme.dim)
        case .saved: Label("Saved to Apple Health as an indoor rowing workout.", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.good)
        case .failed(let message): Label("Couldn't save to Apple Health: \(message)", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad)
        }
    }
}

/// Split per 500 m segment; faster is higher.
struct SplitChart: View {
    let splits: [Double]
    var body: some View {
        let best = splits.min() ?? 0
        Chart(Array(splits.enumerated()), id: \.offset) { item in
            LineMark(x: .value("Segment", Fmt.marker((item.offset + 1) * 500)), y: .value("Split", item.element))
                .foregroundStyle(Theme.amber.opacity(0.6))
            PointMark(x: .value("Segment", Fmt.marker((item.offset + 1) * 500)), y: .value("Split", item.element))
                .foregroundStyle(item.element == best ? Theme.amber : Theme.amber.opacity(0.6))
                .symbolSize(item.element == best ? 120 : 60)
        }
        .chartYScale(domain: .automatic(includesZero: false, reversed: true))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let s = value.as(Double.self) { Text(Fmt.clock(s)).foregroundStyle(Theme.dim) }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.dim) }
        }
    }
}

/// Medals for a regatta event, with what it takes to do better.
private struct EventResult: View {
    let outcome: EventOutcome
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StarRow(count: outcome.stars, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Regatta season · event \(outcome.event.number)")
                Text(outcome.medal + (outcome.improved && outcome.previous > 0 ? " · new best" : "")).font(.headline)
                Text(outcome.hint ?? "Gold. Nothing left to win here.").font(.footnote).foregroundStyle(Theme.dim)
                if let next = outcome.unlockedNext {
                    Text("Next event unlocked: \(next.name)").font(.footnote.weight(.semibold)).foregroundStyle(Theme.good)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Points, XP, coins, new milestones, the journey and today's challenge.
private struct RewardsSection: View {
    let result: RowResult
    @State private var fill = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let xp = result.xp {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("+\(Fmt.meters(Double(xp.gain))) XP").font(Theme.numbers(24, .bold)).foregroundStyle(Theme.amber)
                        Text("\(Fmt.meters(Double(result.score))) points · +\(Fmt.meters(Double(result.score))) coins")
                            .font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
                        Spacer()
                        Text(xp.leveledUp ? "Level up! \(xp.levelAfter) · \(Levels.rank(xp.levelAfter))" : "Level \(xp.levelAfter)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(xp.leveledUp ? Theme.amber : Theme.mist)
                    }
                    ProgressView(value: fill).tint(Theme.amber)
                        .onAppear { withAnimation(.easeOut(duration: 1.2).delay(0.2)) { fill = Levels.fraction(xp: xp.after) } }
                }
            } else if result.score > 0 {
                Text("\(Fmt.meters(Double(result.score))) points").font(Theme.numbers(22)).foregroundStyle(Theme.amber)
            }
            if result.gatesTried > 0 {
                Text("Speed gates: \(result.gatesHit) of \(result.gatesTried)" + (result.bestCombo > 1 ? " · best run ×\(result.bestCombo)" : ""))
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            if !result.newAchievements.isEmpty {
                Eyebrow(text: "New milestones")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(result.newAchievements) { MedalTile(achievement: $0, earned: true) }
                }
            }
            if let j = result.journey {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Journey · \(j.journey.name)")
                    ProgressView(value: j.after / j.journey.meters).tint(Theme.ghost)
                    Text(journeyText(j)).font(.footnote).foregroundStyle(j.complete ? Theme.good : Theme.dim)
                }
            }
            if !result.spotted.isEmpty {
                Label("Spotted on the water: " + result.spotted.map(\.name).joined(separator: ", ") + ".", systemImage: "binoculars")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            if let c = result.challengeText {
                Label(result.challengeDone ? "Daily challenge complete: \(c)" : "Daily challenge: \(c)",
                      systemImage: result.challengeDone ? "star.fill" : "star")
                    .font(.footnote)
                    .foregroundStyle(result.challengeDone ? Theme.amber : Theme.dim)
            }
        }
    }

    private func journeyText(_ j: JourneyLine) -> String {
        let rowed = String(format: "%.1f", (j.after - j.before) / 1000)
        var t = "+\(rowed) km"
        if !j.reached.isEmpty { t += " · reached " + j.reached.joined(separator: ", ") }
        if j.complete { return t + ". You made it to the end." }
        if let next = j.next {
            let left = next.meters - j.after
            t += " · " + (left < 1000 ? "\(Fmt.meters(left)) m" : String(format: "%.1f km", left / 1000)) + " to \(next.name)"
        }
        return t
    }
}

/// Each hard piece of an interval workout against its target.
private struct RepsSection: View {
    let reps: [RepResult]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Reps")
            ForEach(Array(reps.enumerated()), id: \.offset) { i, r in
                HStack {
                    Text("Rep \(i + 1)").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Fmt.clock(r.split, tenths: true)).font(Theme.numbers(18)).foregroundStyle(r.hit ? Theme.good : Theme.bad)
                    Text("target \(Fmt.clock(r.target))").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim).frame(width: 96, alignment: .trailing)
                }
            }
        }
    }
}
