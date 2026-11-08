import Charts
import SwiftData
import SwiftUI

struct ResultsView: View {
    let result: RowResult
    @Environment(RowGame.self) private var game
    @Environment(HealthStore.self) private var health
    @State private var checkingHeartRate = false
    @Query(sort: \RowSession.date, order: .reverse) private var sessions: [RowSession]
    @AppStorage("rival") private var rivalRaw = RivalChoice.best.rawValue
    @AppStorage("paceSplit") private var paceSplit = 130.0

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

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    tile(Fmt.split(result.averageSplit), "avg /500 m")
                    tile(String(format: "%.1f", result.averageRate), "avg s/m")
                    tile("\(Int(result.averageWatts.rounded()))", "avg watts")
                    tile("\(result.strokes)", "strokes")
                }

                heartRateSection

                Eyebrow(text: "Splits")
                if result.splits.isEmpty {
                    Text("Row a full 500 m to see your splits here.").font(.callout).foregroundStyle(Theme.dim)
                } else {
                    SplitChart(splits: result.splits).frame(height: 170)
                }

                healthLine

                HStack(spacing: 10) {
                    Button("Row it again") {
                        Launcher.start(result.piece, sessions: sessions, choice: RivalChoice(rawValue: rivalRaw) ?? .best,
                                       pace: paceSplit, game: game)
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
        .foregroundStyle(Theme.mist)
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

/// Resolves who you race and starts the countdown.
@MainActor
enum Launcher {
    static func start(_ piece: Piece, sessions: [RowSession], choice: RivalChoice, pace: Double, game: RowGame) {
        let rows = sessions.map(\.past)
        let rival = Records.rival(for: piece, choice: choice, paceSplit: pace, rows: rows).rival
        game.start(piece: piece, rival: rival, history: rows)
    }
}
