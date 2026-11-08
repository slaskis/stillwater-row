import SwiftUI

private func km(_ m: Double) -> String { String(format: "%.1f", m / 1000) }
private func toGo(_ m: Double) -> String { m < 1000 ? "\(Fmt.meters(m)) m" : "\(km(m)) km" }

/// Level, rank, coins, streak and lifetime metres.
struct RankCard: View {
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        let s = progress.state
        let level = s.level
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Level \(level)")
                    Text(Levels.rank(level)).font(.system(size: 24, weight: .semibold).width(.condensed))
                }
                Spacer()
                Label("\(Fmt.meters(Double(s.coins)))", systemImage: "circle.hexagongrid.fill")
                    .font(Theme.numbers(20))
                    .foregroundStyle(Theme.amber)
                    .accessibilityLabel("\(s.coins) coins")
            }
            ProgressView(value: Levels.fraction(xp: s.xp)).tint(Theme.amber)
            Text("\(Fmt.meters(Double(Levels.xp(for: level + 1) - s.xp))) XP to level \(level + 1)")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
            HStack(spacing: 24) {
                Stat(value: "\(s.streak())", label: "day streak", size: 22)
                Stat(value: toGo(s.lifetime), label: "lifetime", size: 22)
                Stat(value: "\(s.unlocked.count)/\(Achievement.all.count)", label: "milestones", size: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }
}

/// Today's challenge, the same for everyone on the same day.
struct ChallengeCard: View {
    let sessions: [RowSession]
    @Environment(ProgressStore.self) private var progress
    @AppStorage("gates") private var gatesOn = true
    @AppStorage("rival") private var rivalRaw = RivalChoice.best.rawValue
    @AppStorage("pieceID") private var pieceID = "2k"

    var body: some View {
        let c = challenge
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Daily challenge")
            Text(c.text).font(.headline)
            Text(notes(for: c).joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(progress.challengeDoneToday ? Theme.good : Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }

    private var challenge: DailyChallenge {
        let today = Calendar.current.startOfDay(for: Date())
        return DailyChallenge.today(recentSplit: Records.recentSplit(sessions.map(\.past).filter { $0.date < today }))
    }

    private func notes(for c: DailyChallenge) -> [String] {
        var notes: [String] = [progress.challengeDoneToday ? "Done today ✓" : "+300 points"]
        switch c.need {
        case .gates where !gatesOn: notes.append("turn speed gates on")
        case .storm where pieceID != "storm": notes.append("pick Outrun the storm")
        case .fleet where rivalRaw != RivalChoice.fleet.rawValue: notes.append("choose The fleet")
        default: break
        }
        let total = progress.state.challenges.count
        if total > 0 { notes.append("\(total) completed so far") }
        return notes
    }
}

/// The regatta season: eight events, each unlocked by a medal in the one before.
struct SeasonCard: View {
    let sessions: [RowSession]
    @Environment(RowGame.self) private var game
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        let stars = progress.state.season
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Regatta season")
                Spacer()
                Text("\(progress.state.seasonStars) of \(Season.events.count * 3) stars")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
            }
            ForEach(Array(Season.events.enumerated()), id: \.element.id) { i, ev in
                let open = Season.isUnlocked(i, stars: stars)
                HStack(spacing: 10) {
                    Text("\(i + 1)")
                        .font(Theme.numbers(18))
                        .frame(width: 22)
                        .foregroundStyle(open ? Theme.mist : Theme.dim)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ev.name).font(.subheadline.weight(.semibold))
                        Text(open ? "\(ev.place) · \(ev.goalText)" : "Win a medal in the event before to unlock")
                            .font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    StarRow(count: stars[ev.id] ?? 0)
                    Button(open ? "Row" : "Locked") {
                        Launcher.start(ev.piece, event: ev, sessions: sessions, prefs: .current, progress: progress, game: game)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!open)
                    .opacity(open ? 1 : 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }
}

struct StarRow: View {
    let count: Int
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "star.fill")
                    .font(.system(size: size))
                    .foregroundStyle(i < count ? Theme.amber : Color.white.opacity(0.18))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(count) of 3 stars")
    }
}

/// A long trip that every metre counts towards.
struct JourneyCard: View {
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        let j = progress.journey
        let m = progress.state.journeyMeters(j)
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Journey")
            Picker("Journey", selection: Binding(get: { progress.state.journeyID },
                                                 set: { id in progress.update { $0.journeyID = id } })) {
                ForEach(Journey.all) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                Text(j.subtitle).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(km(m)) of \(Int(j.km)) km").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
            }
            ProgressView(value: m / j.meters).tint(Theme.ghost)
            if let next = j.nextStop(after: m) {
                Text("Last stop \(j.lastStop(at: m).name). \(toGo(next.meters - m)) to \(next.name).")
                    .font(.footnote).foregroundStyle(Theme.dim)
            } else {
                Text("You made it all the way to \(j.stops.last?.name ?? "the end"). Pick another journey.")
                    .font(.footnote).foregroundStyle(Theme.good)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }
}

/// Every milestone, earned ones lit.
struct MilestonesCard: View {
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(text: "Milestones")
                Spacer()
                Text("\(progress.state.unlocked.count) of \(Achievement.all.count)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(Achievement.all) { a in
                    MedalTile(achievement: a, earned: progress.isUnlocked(a.id))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }
}

struct MedalTile: View {
    let achievement: Achievement
    let earned: Bool
    var body: some View {
        VStack(spacing: 4) {
            Text(achievement.code)
                .font(.system(size: 14, weight: .bold).width(.condensed))
                .foregroundStyle(earned ? Color(hex: 0x2b1a05) : Theme.dim)
                .frame(width: 40, height: 40)
                .background(earned ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Color.white.opacity(0.06)), in: Circle())
                .overlay(Circle().strokeBorder(earned ? Color.clear : Theme.line, lineWidth: 1))
            Text(achievement.name).font(.caption2.weight(.semibold)).lineLimit(1)
            Text(achievement.detail).font(.caption2).foregroundStyle(Theme.dim).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .opacity(earned ? 1 : 0.7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(achievement.name), \(achievement.detail), \(earned ? "earned" : "not yet")")
    }
}
