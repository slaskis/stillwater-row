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
                Spacer()
                if let banner = game.banner {
                    VStack(spacing: 2) {
                        Text(banner.title).font(.headline)
                        Text(banner.detail).font(.subheadline).foregroundStyle(Theme.dim)
                    }
                    .panel(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
                    if !game.hud.rivalTitle.isEmpty { RivalPanel() }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("View") { game.cycleCamera() }
                        Button("Pause") { game.pause() }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .padding()
            .animation(.easeOut(duration: 0.3), value: game.banner)

            if game.phase == .countdown, !game.countdownText.isEmpty {
                Text(game.countdownText.uppercased())
                    .font(.system(size: 110, weight: .bold).width(.condensed))
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 4)
                    .allowsHitTesting(false)
                    .id(game.countdownText)
                    .transition(.scale.combined(with: .opacity))
            }

            if game.phase == .paused { PausePanel() }
        }
        .foregroundStyle(Theme.mist)
    }
}

private struct PiecePanel: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Piece")
            Text(game.pieceName).font(.system(size: 22, weight: .semibold).width(.condensed))
            ProgressView(value: game.hud.progress).tint(Theme.amber)
            Text(game.hud.progressText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
        .frame(width: 230, alignment: .leading)
        .panel(14)
    }
}

private struct SplitPanel: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        VStack(spacing: 2) {
            Text(Fmt.split(game.hud.split))
                .font(Theme.numbers(88, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 10) {
                Eyebrow(text: "Split / 500 m")
                if let hr = game.hud.heartRate {
                    Label("\(hr)", systemImage: "heart.fill")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.bad)
                }
            }
        }
        .frame(width: 270)
        .padding(.vertical, 4)
        .panel(12)
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

private struct RivalPanel: View {
    @Environment(RowGame.self) private var game
    var body: some View {
        let gap = game.hud.gap
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                (Text("Racing ") + Text(game.hud.rivalTitle).foregroundStyle(Theme.ghost).bold())
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                GapTrack(gap: gap).frame(height: 18)
            }
            Text((gap >= 0 ? "+" : "−") + String(format: "%.1f m", abs(gap)))
                .font(Theme.numbers(28, .bold))
                .foregroundStyle(abs(gap) < 0.5 ? Theme.mist : (gap > 0 ? Theme.good : Theme.bad))
                .frame(width: 120, alignment: .trailing)
        }
        .frame(maxWidth: 560)
        .panel(14)
    }
}

/// You (amber) and your rival (outlined) on a line, spread by the gap between you.
private struct GapTrack: View {
    let gap: Double
    var body: some View {
        GeometryReader { geo in
            let span = max(20, abs(gap) * 1.4)
            let me = clamp(0.5 + gap / span * 0.45, 0.04, 0.96)
            let rival = clamp(0.5 - gap / span * 0.45, 0.04, 0.96)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 2)
                Circle().strokeBorder(Theme.ghost, lineWidth: 2).frame(width: 14, height: 14)
                    .offset(x: geo.size.width * rival - 7)
                Circle().fill(Theme.amber).frame(width: 14, height: 14)
                    .offset(x: geo.size.width * me - 7)
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.25), value: gap)
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
