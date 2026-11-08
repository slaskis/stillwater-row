import SwiftData
import SwiftUI

/// The dock: pick a piece and a rival, connect the rower and Apple Health, see your logbook.
struct HomeView: View {
    @Environment(RowGame.self) private var game
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \RowSession.date, order: .reverse) private var sessions: [RowSession]

    @AppStorage("pieceID") private var pieceID = "2k"
    @AppStorage("rival") private var rivalRaw = RivalChoice.best.rawValue
    @AppStorage("paceSplit") private var paceSplit = 130.0
    @AppStorage("cox") private var coxOn = true

    private var piece: Piece { Piece.with(id: pieceID) }
    private var choice: RivalChoice { RivalChoice(rawValue: rivalRaw) ?? .best }

    var body: some View {
        ScrollView {
            Group {
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 14) { left }.frame(maxWidth: 460)
                        VStack(spacing: 14) { right }.frame(maxWidth: 460)
                    }
                } else {
                    VStack(spacing: 14) { left; right }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(
            LinearGradient(colors: [Theme.ink.opacity(0.6), Theme.ink.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
        )
        .foregroundStyle(Theme.mist)
        .onAppear { game.cox.enabled = coxOn }
        .onChange(of: coxOn) { _, on in game.cox.enabled = on }
    }

    @ViewBuilder private var left: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stillwater Row").font(.system(size: 42, weight: .bold).width(.condensed))
            Text("October on the river. Pick a piece, choose who to race, and row.").foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)

        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Piece")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Piece.all) { p in pieceButton(p) }
            }
        }
        .panel(18)

        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Race against")
            Picker("Race against", selection: $rivalRaw) {
                ForEach(RivalChoice.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                Button { paceSplit = max(90, paceSplit - 5) } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Faster pace boat")
                Text(Fmt.clock(paceSplit)).font(Theme.numbers(24)).frame(width: 60)
                Button { paceSplit = min(240, paceSplit + 5) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Slower pace boat")
                Text("pace boat split / 500 m").font(.footnote).foregroundStyle(Theme.dim)
            }
            .buttonStyle(QuietButtonStyle())
            Text(rivalNote).font(.footnote).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .panel(18)

        Button("Sit ready") {
            Launcher.start(piece, sessions: sessions, choice: choice, pace: paceSplit, game: game)
        }
        .buttonStyle(PrimaryButtonStyle())

        Toggle(isOn: $coxOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cox voice")
                Text("Using \(game.cox.voiceDescription)." + (game.cox.hasGoodVoice ? "" : " For a more natural voice, download an Enhanced or Premium English voice in Settings › Accessibility › Spoken Content › Voices."))
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
            }
        }
        .tint(Theme.amber)
        .panel(18)
    }

    @ViewBuilder private var right: some View {
        RowerCard()
        HealthCard()
        LogbookCard(sessions: sessions)
    }

    private var rivalNote: String {
        let rows = sessions.map(\.past)
        let resolved = Records.rival(for: piece, choice: choice, paceSplit: paceSplit, rows: rows)
        switch resolved.rival {
        case .ghost:
            return "Your ghost replays that row second by second in the next lane."
        case .paceBoat(let split):
            if resolved.fellBack {
                return "No \(piece.name) on record yet, so a pace boat at \(Fmt.clock(split)) stands in. Row one and it becomes your ghost."
            }
            return "A steady boat holding the split above, all the way."
        }
    }

    private func pieceButton(_ p: Piece) -> some View {
        let best = Records.best(for: p, in: sessions.map(\.past))
        let bestText: String = {
            guard let best else { return "No result yet" }
            switch p.goal {
            case .distance: return "Best " + Fmt.clock(best.duration, tenths: true)
            case .time: return "Best \(Fmt.meters(best.distance)) m"
            case .open: return "Longest \(Fmt.meters(best.distance)) m"
            }
        }()
        let selected = p.id == pieceID
        return Button { pieceID = p.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 22, weight: .semibold).width(.condensed))
                Text(p.subtitle).font(.caption).foregroundStyle(Theme.dim)
                Text(bestText).font(.caption.monospacedDigit()).foregroundStyle(Theme.ghost).padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected ? Theme.amber.opacity(0.12) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.amber : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Connect the rowing console and an optional heart-rate strap.
struct RowerCard: View {
    @Environment(BluetoothLink.self) private var link

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Rower")
            if let problem = link.problem {
                Text(problem).font(.callout).foregroundStyle(Theme.bad)
            }
            if let name = link.rowerName {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline)
                        Text(rowerStatus).font(.footnote).foregroundStyle(link.rowerReady ? Theme.good : Theme.dim)
                    }
                    Spacer()
                    Button("Forget") { link.forgetRower() }.buttonStyle(QuietButtonStyle())
                }
            } else {
                Text("Not connected. Tapping the screen once per stroke works without it.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            if let hr = link.heartRateName {
                HStack {
                    Label(link.heartRate.map { "\(hr) · \($0) bpm" } ?? "\(hr) · waiting", systemImage: "heart.fill")
                        .font(.footnote)
                    Spacer()
                    Button("Forget") { link.forgetStrap() }.buttonStyle(QuietButtonStyle())
                }
            }
            Button(link.scanning ? "Searching…" : "Find rower or heart-rate strap") { link.startScan() }
                .buttonStyle(QuietButtonStyle())
                .disabled(link.scanning)
            ForEach(link.found) { device in
                Button { link.connect(device) } label: {
                    HStack {
                        Image(systemName: device.kind == .rower ? "figure.rower" : "heart.fill")
                        Text(device.name)
                        Spacer()
                        Text("Connect").foregroundStyle(Theme.amber)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }

    private var rowerStatus: String {
        if link.rowerReady { return "Receiving strokes and metres from the console" }
        if link.rowerConnecting { return "Waiting for the console. Wake it with a stroke." }
        return "Connected, waiting for data"
    }
}

/// Apple Health: save rows as workouts and read heart rate.
struct HealthCard: View {
    @Environment(HealthStore.self) private var health

    var body: some View {
        @Bindable var health = health
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Apple Health")
            if !health.available {
                Text("Apple Health isn't available on this device.").font(.footnote).foregroundStyle(Theme.dim)
            } else if !health.asked {
                Text("Save each row as an indoor rowing workout, and see the heart rate your watch recorded.")
                    .font(.footnote).foregroundStyle(Theme.dim)
                Button("Connect Apple Health") { Task { await health.requestAccess() } }
                    .buttonStyle(QuietButtonStyle())
            } else {
                Toggle("Save rows as workouts", isOn: $health.saveRows)
                    .tint(Theme.amber)
                    .disabled(!health.canSave)
                if !health.canSave {
                    Text("Saving is turned off for Stillwater. Turn it on in the Health app › your profile › Apps › Stillwater.")
                        .font(.footnote).foregroundStyle(Theme.bad)
                }
                Text("Heart rate comes from whatever records it into Apple Health. A Withings watch records every second if you start a workout on the watch, and its app syncs to Health afterwards.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            if let error = health.lastError {
                Text(error).font(.footnote).foregroundStyle(Theme.bad)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }
}

/// Your rows, plus rowing from other apps in Apple Health.
struct LogbookCard: View {
    let sessions: [RowSession]
    @Environment(HealthStore.self) private var health

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Logbook")
                Spacer()
                let total = sessions.reduce(0) { $0 + $1.distance }
                Text("\(sessions.count) rows · \(Fmt.meters(total)) m").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
            }
            if sessions.isEmpty {
                Text("Your rows will be logged here. Each one becomes a ghost you can race on the same piece.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
            ForEach(sessions.prefix(6)) { s in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.piece.name).font(.subheadline.weight(.semibold))
                        Text(s.date.formatted(date: .abbreviated, time: .shortened) + (s.complete || !s.piece.isDistance ? "" : " · stopped early"))
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    if s.healthWorkoutID != nil {
                        Image(systemName: "heart.text.square").foregroundStyle(Theme.dim).accessibilityLabel("In Apple Health")
                    }
                    if let hr = s.averageHeartRate {
                        Text("\(Int(hr.rounded())) bpm").font(.footnote.monospacedDigit()).foregroundStyle(Theme.bad)
                    }
                    Text("\(Fmt.meters(s.distance)) m").font(Theme.numbers(17))
                    Text(Fmt.clock(s.duration, tenths: true)).font(Theme.numbers(17)).frame(width: 64, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }

            let others = health.history.filter { !$0.isOwn }
            if !others.isEmpty {
                Eyebrow(text: "Other rowing in Apple Health").padding(.top, 6)
                ForEach(others.prefix(5)) { w in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.source).font(.subheadline.weight(.semibold))
                            Text(w.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        if let d = w.distance { Text("\(Fmt.meters(d)) m").font(Theme.numbers(17)) }
                        Text(Fmt.clock(w.duration)).font(Theme.numbers(17)).frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }
}
