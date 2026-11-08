import SwiftUI

/// The rowing monitor laid over the river.
struct RowingView: View {
    @Environment(RowGame.self) private var game
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            // Taps anywhere off the panels count as strokes.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { game.tap() }
                .accessibilityLabel("Take a stroke")
                .accessibilityAddTraits(.isButton)

            VStack(spacing: 12) {
                if sizeClass == .compact {
                    SplitPanel()
                    StatsPanel()
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        PiecePanel()
                        Spacer(minLength: 8)
                        SplitPanel()
                        Spacer(minLength: 8)
                        StatsPanel()
                    }
                }
                BannerStack()
                Spacer()
                if let pop = game.pop {
                    Text(pop.text)
                        .font(Theme.numbers(34, .bold))
                        .foregroundStyle(pop.good ? Theme.good : Theme.bad)
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                        .id(pop.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
                if let p10 = game.hud.power10 {
                    Text(p10)
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .foregroundStyle(game.hud.power10Calling ? Theme.amber : Color(hex: 0x2b1a05))
                        .background(game.hud.power10Calling ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Theme.amber), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.amber, lineWidth: 1))
                        .allowsHitTesting(false)
                }
                if let hint = game.hint, game.phase == .rowing {
                    Text(hint)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.ink.opacity(0.55), in: Capsule())
                        .allowsHitTesting(false)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    if let race = game.hud.race { RacePanelView(race: race) }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("View") { game.cycleCamera() }
                        Button("Pause") { game.pause() }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .padding()
            .animation(.easeOut(duration: 0.3), value: game.banners)
            .animation(.easeOut(duration: 0.25), value: game.pop)

            if let ev = game.eventIntro {
                EventIntro(event: ev).transition(.opacity).allowsHitTesting(false)
            } else if game.phase == .countdown, !game.countdownText.isEmpty {
                Text(game.countdownText.uppercased())
                    .font(.system(size: 110, weight: .bold).width(.condensed))
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 4)
                    .allowsHitTesting(false)
                    .id(game.countdownText)
                    .transition(.scale.combined(with: .opacity))
            }

            if game.phase == .paused { PausePanel() }
        }
        .animation(.easeInOut(duration: 0.3), value: game.eventIntro)
        .foregroundStyle(Theme.mist)
    }
}

private struct BannerStack: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        VStack(spacing: 6) {
            ForEach(game.banners) { b in
                HStack(spacing: 10) {
                    if let medal = b.medal {
                        Text(medal)
                            .font(.system(size: 13, weight: .bold).width(.condensed))
                            .foregroundStyle(Color(hex: 0x2b1a05))
                            .frame(width: 34, height: 34)
                            .background(Theme.amber, in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.title).font(.headline)
                        Text(b.detail).font(.subheadline).foregroundStyle(Theme.dim).lineLimit(2)
                    }
                }
                .frame(maxWidth: 420)
                .panel(10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct EventIntro: View {
    let event: SeasonEvent
    var body: some View {
        VStack(spacing: 8) {
            Eyebrow(text: "Event \(event.number) · \(event.place)")
            Text(event.name).font(.system(size: 56, weight: .bold).width(.condensed)).multilineTextAlignment(.center)
            Text(event.goalText).font(.title3).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .padding(28)
        .panel(0)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
    }
}

private struct PiecePanel: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Piece")
            Text(game.pieceName).font(.system(size: 22, weight: .semibold).width(.condensed)).lineLimit(1)
            ProgressView(value: game.hud.progress).tint(Theme.amber)
            Text(game.hud.progressText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            if let gate = game.hud.gate {
                Text(gate.text)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(gate.tone == .good ? Theme.good : gate.tone == .bad ? Theme.bad : Theme.dim)
                    .lineLimit(1)
            }
        }
        .frame(width: 230, alignment: .leading)
        .panel(14)
    }
}

private struct SplitPanel: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        let zone = game.hud.inZone
        VStack(spacing: 2) {
            Text(Fmt.split(game.hud.split))
                .font(Theme.numbers(88, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 10) {
                Eyebrow(text: zone ? "In the zone" : "Split / 500 m")
                if let hr = game.hud.heartRate {
                    Label("\(hr)", systemImage: "heart.fill")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.bad)
                }
            }
            // Rhythm flow: fills as your stroke rate holds steady.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(zone ? Theme.amber : Theme.ghost).frame(width: geo.size.width * game.hud.flow)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .animation(.easeOut(duration: 0.4), value: game.hud.flow)
            .accessibilityLabel("Rhythm \(Int(game.hud.flow * 100)) percent")
        }
        .frame(width: 270)
        .padding(.vertical, 4)
        .panel(12)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.amber, lineWidth: zone ? 2 : 0))
        .shadow(color: zone ? Theme.amber.opacity(0.35) : .clear, radius: 18)
    }
}

private struct StatsPanel: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        let h = game.hud
        Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow {
                Stat(value: Fmt.meters(h.meters), label: "metres", alignment: .trailing).frame(width: 90, alignment: .trailing)
                Stat(value: Fmt.clock(h.time), label: "time", alignment: .trailing).frame(width: 90, alignment: .trailing)
            }
            GridRow {
                Stat(value: "\(Int(h.strokeRate.rounded()))", label: "s/m", alignment: .trailing).frame(width: 90, alignment: .trailing)
                Stat(value: "\(Int(h.watts.rounded()))", label: "watts", alignment: .trailing).frame(width: 90, alignment: .trailing)
            }
        }
        .panel(14)
    }
}

private struct RacePanelView: View {
    let race: RacePanel
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(race.title)
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                GapTrack(me: race.me, other: race.other).frame(height: 18)
            }
            Text(race.value)
                .font(Theme.numbers(28, .bold))
                .foregroundStyle(race.tone == .good ? Theme.good : race.tone == .bad ? Theme.bad : Theme.mist)
                .frame(width: 120, alignment: .trailing)
        }
        .frame(maxWidth: 560)
        .panel(14)
    }
}

/// You (amber) and your rival (outlined) on a line.
private struct GapTrack: View {
    let me: Double
    let other: Double?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 2)
                if let other {
                    Circle().strokeBorder(Theme.ghost, lineWidth: 2).frame(width: 14, height: 14)
                        .offset(x: geo.size.width * other - 7)
                }
                Circle().fill(Theme.amber).frame(width: 14, height: 14)
                    .offset(x: geo.size.width * me - 7)
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.25), value: me)
            .animation(.linear(duration: 0.25), value: other)
        }
    }
}

private struct PausePanel: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        VStack(spacing: 12) {
            Text("Easy oar").font(.system(size: 34, weight: .bold).width(.condensed))
            Button("Resume") { game.resume() }.buttonStyle(PrimaryButtonStyle())
            Button("End session") { game.endSession() }
                .buttonStyle(QuietButtonStyle())
                .frame(maxWidth: .infinity)
        }
        .frame(width: 320)
        .panel(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }
}
