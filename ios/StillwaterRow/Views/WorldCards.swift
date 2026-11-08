import SwiftUI

/// Weather, scenery, music, sound effects and the rate beat.
struct WaterCard: View {
    @Environment(RowGame.self) private var game
    @Environment(ProgressStore.self) private var progress
    @AppStorage("condition") private var condition = "auto"
    @AppStorage("scenery") private var scenery = "auto"
    @AppStorage("music") private var music = true
    @AppStorage("effects") private var effects = true
    @AppStorage("beat") private var beat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "On the water")
            Picker("Weather", selection: $condition) {
                Text("Follow the clock").tag("auto")
                ForEach(Condition.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .tint(Theme.mist)
            Picker("Scenery", selection: $scenery) {
                Text("Auto").tag("auto")
                ForEach(Scenery.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text(scenery == "auto" ? "Auto rows the archipelago while you're on the archipelago journey, and the forest river otherwise." : " ")
                .font(.caption).foregroundStyle(Theme.dim)
            Toggle("Music that follows your stroke rate", isOn: $music).tint(Theme.amber)
            Toggle("Sound effects", isOn: $effects).tint(Theme.amber)
            HStack {
                Text("Rate beat")
                Spacer()
                Picker("Rate beat", selection: $beat) {
                    Text("Off").tag(0)
                    Text("20").tag(20)
                    Text("24").tag(24)
                    Text("28").tag(28)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
        .onChange(of: condition) { refresh() }
        .onChange(of: scenery) { refresh() }
        .onChange(of: progress.state.journeyID) { refresh() }
        .onChange(of: effects) { game.sound.effectsEnabled = effects }
    }

    private func refresh() {
        let p = Launcher.Prefs.current
        game.setHomeLook(p.resolvedCondition(), scenery: p.resolvedScenery(journey: progress.state.journeyID))
    }
}

/// Spend coins on hats, crew, flags and wakes; liveries unlock with your level.
struct ShopCard: View {
    @Environment(RowGame.self) private var game
    @Environment(ProgressStore.self) private var progress
    @State private var category: ShopCategory = .hat
    @State private var confirm: ShopItem?

    var body: some View {
        let s = progress.state
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Boat shop")
                Spacer()
                Label("\(Fmt.meters(Double(s.coins))) coins", systemImage: "circle.hexagongrid.fill")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.amber)
            }
            Picker("Category", selection: $category) {
                ForEach(ShopCategory.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ShopItem.all.filter { $0.category == category }) { item in itemButton(item, state: s) }
            }

            Eyebrow(text: "Livery")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Livery.all) { l in liveryButton(l, state: s) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
        .confirmationDialog(confirm.map { "Buy \($0.name) for \(Fmt.meters(Double($0.price))) coins?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button("Buy") {
                if let item = confirm, progress.shop(item) == .bought {
                    game.sound.chime()
                    game.dressBoat()
                }
                confirm = nil
            }
            Button("Not now", role: .cancel) { confirm = nil }
        }
    }

    private func itemButton(_ item: ShopItem, state s: ProgressState) -> some View {
        let owned = s.owned.contains(item.id)
        let wearing = s.cosmetics[item.category] == item.id
        let poor = !owned && s.coins < item.price
        return Button {
            if owned {
                progress.shop(item)
                game.dressBoat()
            } else {
                confirm = item
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.mist)
                Text(wearing ? "Wearing · tap to remove" : owned ? "Owned · tap to wear" : "\(Fmt.meters(Double(item.price))) coins")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(wearing ? Theme.good : poor ? Theme.dim : Theme.amber)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.white.opacity(wearing ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(wearing ? Theme.good : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(poor)
        .opacity(poor ? 0.55 : 1)
    }

    private func liveryButton(_ l: Livery, state s: ProgressState) -> some View {
        let open = s.hasLivery(l)
        let on = s.livery == l.id
        return Button {
            progress.update { $0.livery = l.id }
            game.dressBoat()
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    Color(hex: l.hull)
                    Color(hex: l.shirt)
                    Color(hex: l.blade)
                }
                .frame(width: 66, height: 18)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.amber : Theme.line, lineWidth: on ? 2 : 1))
                Text(l.name).font(.caption2.weight(.semibold)).lineLimit(1)
                Text(open ? (on ? "In use" : "Use") : "Level \(l.level)").font(.caption2).foregroundStyle(on ? Theme.amber : Theme.dim)
            }
            .frame(width: 84)
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .opacity(open ? 1 : 0.5)
        .accessibilityLabel("\(l.name) livery, \(open ? (on ? "in use" : "available") : "unlocks at level \(l.level)")")
    }
}

/// Animals you've spotted from the boat.
struct FieldGuideCard: View {
    @Environment(ProgressStore.self) private var progress

    var body: some View {
        let seen = progress.state.wildlife
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(text: "Field guide")
                Spacer()
                Text("\(progress.state.animalsSeen) of \(Animal.allCases.count) spotted").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Animal.allCases) { a in
                    let n = seen[a.rawValue] ?? 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n > 0 ? a.name : "Not seen yet").font(.subheadline.weight(.semibold))
                            .foregroundStyle(n > 0 ? Theme.mist : Theme.dim)
                        Text(n > 0 ? "\(a.rarity) · seen \(n)×" : a.rarity + (a.habitat.map { " · \($0.name.lowercased())" } ?? ""))
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(n > 0 ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
    }
}

/// Paper confetti falling over the results.
struct ConfettiView: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var done = false

    private struct Piece {
        let x: Double, delay: Double, speed: Double, drift: Double, spin: Double, w: Double, h: Double, phase: Double
        let color: Color
    }

    private static let colors: [Color] = [Color(hex: 0xf2b25c), Color(hex: 0x8fe1ee), Color(hex: 0x86d9a6),
                                          Color(hex: 0xf29a84), Color(hex: 0xe7eff0), Color(hex: 0xe8743a)]

    private var pieces: [Piece] {
        var rng = Mulberry32(seed: count)
        return (0..<count).map { i in
            Piece(x: rng.next(), delay: rng.next() * 0.8, speed: 140 + rng.next() * 200, drift: (rng.next() - 0.5) * 120,
                  spin: (rng.next() - 0.5) * 10, w: 6 + rng.next() * 7, h: 3 + rng.next() * 4, phase: rng.next() * 6,
                  color: Self.colors[i % Self.colors.count])
        }
    }

    var body: some View {
        if reduceMotion || done {
            EmptyView()
        } else {
            let list = pieces
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSince(start)
                Canvas { ctx, size in
                    for p in list {
                        let tt = t - p.delay
                        guard tt > 0 else { continue }
                        let y = -20 + p.speed * tt + 20 * tt * tt
                        guard y < size.height + 30 else { continue }
                        let x = p.x * size.width + p.drift * tt + sin(tt * 3 + p.phase) * 30
                        var c = ctx
                        c.translateBy(x: x, y: y)
                        c.rotate(by: .radians(p.phase + p.spin * tt))
                        c.scaleBy(x: 1, y: cos(tt * 5.5 + p.phase))
                        c.fill(Path(CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)), with: .color(p.color))
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .task {
                try? await Task.sleep(for: .seconds(6))
                done = true
            }
        }
    }
}
