import SceneKit
import SwiftData
import SwiftUI

/// The SceneKit river, always running behind every screen.
struct RiverView: UIViewRepresentable {
    let game: RowGame

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = game.world.scene
        view.pointOfView = game.world.cameraNode
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        view.isPlaying = true
        game.startLoop()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

struct RootView: View {
    @Environment(RowGame.self) private var game
    @Environment(BluetoothLink.self) private var link
    @Environment(HealthStore.self) private var health
    @Environment(ProgressStore.self) private var progress
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            RiverView(game: game).ignoresSafeArea()
            switch game.phase {
            case .home:
                HomeView().transition(.opacity)
            case .countdown, .rowing, .paused:
                RowingView().transition(.opacity)
            case .finished:
                if let result = game.result {
                    ResultsView(result: result).transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: game.phase)
        .onAppear(perform: wire)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { game.pause() }
            if newPhase == .active { health.refreshStatus() }
        }
    }

    private func wire() {
        game.attach(link: link, progress: progress)
        link.resume()
        let context = context, health = health, game = game
        game.onFinish = { result in
            Recorder.record(result, context: context, health: health, game: game)
        }
        Task { await health.loadHistory() }
    }
}

/// Saves finished rows locally and to Apple Health, then fetches heart rate for them.
@MainActor
enum Recorder {
    private(set) static var lastRecord: RowSession?

    static func record(_ result: RowResult, context: ModelContext, health: HealthStore, game: RowGame) {
        guard result.saveable else { return }
        let record = RowSession(result: result)
        context.insert(record)
        try? context.save()
        lastRecord = record
        Task {
            if health.available, health.canSave, health.saveRows {
                game.updateResult { $0.health = .saving }
                do {
                    record.healthWorkoutID = try await health.save(result)
                    game.updateResult { $0.health = .saved }
                    await health.loadHistory()
                } catch {
                    game.updateResult { $0.health = .failed(error.localizedDescription) }
                }
            }
            await refreshHeartRate(health: health, game: game)
            try? context.save()
        }
    }

    /// Heart rate shows up once your watch has synced to Apple Health, which can take a while.
    static func refreshHeartRate(health: HealthStore, game: RowGame) async {
        guard let record = lastRecord,
              let hr = await health.heartRate(from: record.date, to: record.end) else { return }
        record.averageHeartRate = hr.average
        record.maxHeartRate = hr.max
        game.updateResult { $0.heartRate = hr }
    }
}
