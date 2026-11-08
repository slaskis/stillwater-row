import Observation
import QuartzCore
import UIKit

struct HUDState: Equatable {
    var split: Double = .infinity
    var meters: Double = 0
    var time: Double = 0
    var strokeRate: Double = 0
    var watts: Double = 0
    var heartRate: Int? = nil
    var progress: Double = 0
    var progressText = "Take your first stroke"
    var rivalTitle = ""
    var gap: Double = 0
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

private final class DisplayLinkProxy: NSObject {
    let handler: (CADisplayLink) -> Void
    init(_ handler: @escaping (CADisplayLink) -> Void) { self.handler = handler }
    @objc func tick(_ link: CADisplayLink) { handler(link) }
}

/// Runs a row: the frame loop, strokes from taps or the console, the rival, splits, cox calls and the finish.
@MainActor @Observable
final class RowGame {
    enum Phase: Equatable { case home, countdown, rowing, paused, finished }

    var phase: Phase = .home
    var countdownText = ""
    var hud = HUDState()
    var banner: Banner?
    var result: RowResult?
    var pieceName = ""
    var hint: String?
    var cameraMode = 0 { didSet { world.cameraMode = cameraMode } }

    let world = RiverScene()
    let cox = Cox()
    @ObservationIgnored var onFinish: ((RowResult) -> Void)?

    @ObservationIgnored private weak var link: BluetoothLink?
    @ObservationIgnored private var physics = RowPhysics()
    @ObservationIgnored private var engine: SessionEngine?
    @ObservationIgnored private var rival: Rival?
    @ObservationIgnored private var history: [PastRow] = []
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private var simT: Double = 0
    @ObservationIgnored private var lastStrokeAt: Double = -10
    @ObservationIgnored private var nextDemoStroke: Double = 1
    @ObservationIgnored private var hudClock: Double = 0
    @ObservationIgnored private var consoleBase: Double = 0
    @ObservationIgnored private var ghostNextStroke: Double = 0
    @ObservationIgnored private var gapSign = 0
    @ObservationIgnored private var calls: Set<String> = []
    @ObservationIgnored private var lastReport: Double = 0
    @ObservationIgnored private var stopCalled = false
    @ObservationIgnored private var countdownToken = 0

    init() {
        physics.v = 3.6   // already gliding when the app opens
    }

    var usingConsole: Bool { link?.rowerReady ?? false }

    func attach(link: BluetoothLink) {
        self.link = link
        link.onStroke = { [weak self] in
            MainActor.assumeIsolated { self?.stroke(fromConsole: true) }
        }
    }

    func startLoop() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] dl in
            MainActor.assumeIsolated { self?.frame(dl) }
        }
        let dl = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    // MARK: - Session control

    func start(piece: Piece, rival: Rival?, history: [PastRow]) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.history = history
        self.rival = rival
        engine = SessionEngine(piece: piece)
        pieceName = piece.name
        physics.reset()
        lastStrokeAt = simT - 10
        ghostNextStroke = 0
        gapSign = 0
        calls.removeAll()
        lastReport = 0
        stopCalled = false
        consoleBase = link?.consoleDistance ?? 0
        world.reset(finishAt: piece.finishDistance)
        if let rival { world.ghost.setLabel(rival.tag) }
        result = nil
        banner = nil
        hint = usingConsole ? "Row when ready. The clock starts on your first stroke." : "Tap anywhere on each stroke"
        hud = HUDState(rivalTitle: rival?.title ?? "")
        runCountdown()
    }

    func tap() {
        guard phase == .rowing, !usingConsole else { return }
        stroke(fromConsole: false)
    }

    func pause() {
        guard phase == .rowing || phase == .countdown else { return }
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        lastFrame = 0
        phase = .rowing
    }

    func endSession() {
        if phase == .paused { phase = .rowing }
        finish(complete: false)
    }

    func backToDock() {
        UIApplication.shared.isIdleTimerDisabled = false
        engine = nil
        rival = nil
        result = nil
        banner = nil
        hint = nil
        world.reset(finishAt: nil)
        world.ghost.root.isHidden = true
        nextDemoStroke = simT + 1
        phase = .home
    }

    func updateResult(_ change: (inout RowResult) -> Void) {
        guard var r = result else { return }
        change(&r)
        result = r
    }

    func cycleCamera() { cameraMode = (cameraMode + 1) % 3 }

    // MARK: - Frame loop

    private func frame(_ dl: CADisplayLink) {
        let now = dl.timestamp
        let dt = lastFrame == 0 ? 1.0 / 60 : min(max(now - lastFrame, 0), 0.05)
        lastFrame = now
        guard phase != .paused else { return }
        simT += dt

        if phase == .home && simT >= nextDemoStroke {
            nextDemoStroke = simT + 2.7 + Double.random(in: 0...0.15)
            physics.tapStroke()
            world.boat.stroke(recovery: 1.9)
            lastStrokeAt = simT
        }
        stepPhysics(dt)

        if phase == .rowing, var eng = engine {
            let completed = eng.advance(dt: dt, distance: physics.d, watts: currentWatts)
            engine = eng
            for segment in completed { splitDone(segment, engine: eng) }
            if eng.started { raceCalls(eng) }
            if eng.isComplete(distance: physics.d) { finish(complete: true) }
        }

        var ghostDistance: Double?
        if let rival, let eng = engine, phase != .home {
            let t = eng.started ? eng.t : 0
            let gd = rival.distance(at: t, finish: eng.piece.finishDistance)
            ghostDistance = gd
            let moving = phase == .rowing && eng.started && rival.distance(at: t + 0.5, finish: eng.piece.finishDistance) - gd > 0.25
            if moving && simT >= ghostNextStroke {
                let period = 60 / max(rival.strokeRate, 16)
                ghostNextStroke = simT + period
                world.ghost.stroke(recovery: period - RowPhysics.driveTime)
            }
        }
        world.update(dt: dt, time: simT, distance: physics.d, ghostDistance: ghostDistance)

        hudClock += dt
        if hudClock >= 0.1, phase == .rowing || phase == .countdown {
            hudClock = 0
            refreshHUD()
        }
    }

    private var currentWatts: Double {
        if let link, link.rowerReady, link.power > 0 { return link.power }
        return RowPhysics.watts(speed: physics.v)
    }

    private func stepPhysics(_ dt: Double) {
        if phase == .rowing, let link, link.rowerReady {
            let consoleD = max(0, link.consoleDistance - consoleBase)
            let idle = simT - lastStrokeAt
            var target = link.pace > 0 ? 500 / link.pace : link.derivedSpeed
            if idle > 6 { target *= pow(0.6, idle - 6) }
            let rowing = (engine?.started ?? false) && idle < max(3, 1.6 * 60 / max(link.strokeRate, 12))
            let surge = world.boat.isDriving ? 1.14 : (world.boat.recoveryProgress < 0.5 ? 0.94 : 1)
            physics.stepDevice(dt: dt, consoleDistance: consoleD, targetSpeed: target, rowing: rowing, surge: surge)
        } else {
            physics.stepTap(dt: dt)
            if phase == .countdown { physics.v *= 0.98 }
        }
    }

    private func stroke(fromConsole: Bool) {
        guard phase == .rowing || phase == .home else { return }
        let gap = simT - lastStrokeAt
        if !fromConsole && gap < 0.55 { return }       // ignore double taps
        lastStrokeAt = simT
        if !fromConsole { physics.tapStroke() }
        world.boat.stroke(recovery: gap - RowPhysics.driveTime)
        guard phase == .rowing, var eng = engine else { return }
        eng.stroke(at: simT)
        engine = eng
        stopCalled = false
        if eng.strokes == 6 { hint = nil }
    }

    private func refreshHUD() {
        guard let eng = engine else { return }
        var h = HUDState()
        h.split = physics.v > 0.3 ? 500 / physics.v : .infinity
        h.meters = physics.d
        h.time = eng.t
        h.strokeRate = usingConsole ? (link?.strokeRate ?? 0) : eng.strokeRate(now: simT)
        h.watts = currentWatts
        h.heartRate = link?.heartRate
        h.progress = eng.progress(distance: physics.d)
        h.progressText = eng.progressText(distance: physics.d, connected: usingConsole)
        if let rival {
            h.rivalTitle = rival.title
            h.gap = physics.d - rival.distance(at: eng.t, finish: eng.piece.finishDistance)
        }
        hud = h
    }

    private func runCountdown() {
        countdownToken += 1
        let token = countdownToken
        phase = .countdown
        let steps: [(text: String, seconds: Double)] = [("Sit ready", 1.3), ("Attention", 1.3), ("Row!", 0.7)]
        Task { [weak self] in
            for (i, step) in steps.enumerated() {
                guard let self, self.countdownToken == token, self.phase == .countdown else { return }
                self.countdownText = step.text
                self.cox.say(i == 2 ? Cox.pick(["Go!", "Row!", "Attention. Go!"]) : step.text, interrupt: true)
                try? await Task.sleep(for: .seconds(step.seconds))
            }
            guard let self, self.countdownToken == token, self.phase == .countdown else { return }
            self.countdownText = ""
            self.phase = .rowing
        }
    }

    // MARK: - Calls

    private func show(_ title: String, _ detail: String) {
        let b = Banner(title: title, detail: detail)
        banner = b
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            if self?.banner?.id == b.id { self?.banner = nil }
        }
    }

    private func splitDone(_ segment: Double, engine eng: SessionEngine) {
        let metres = eng.splits.count * 500
        if let finish = eng.piece.finishDistance, Double(metres) >= finish { return }
        show(Fmt.marker(metres), "Split \(Fmt.clock(segment, tenths: true)) /500 m")
        let d = Fmt.spokenDistance(metres), s = Fmt.spokenSplit(segment)
        cox.say(Cox.pick(["\(d). Split \(s).", "That's \(d), sitting at \(s).", "\(d) gone. \(s) split."]))
    }

    private func once(_ key: String, _ line: String, interrupt: Bool = true) {
        guard !calls.contains(key) else { return }
        calls.insert(key)
        cox.say(line, interrupt: interrupt)
    }

    private func raceCalls(_ eng: SessionEngine) {
        let t = eng.t
        switch eng.piece.goal {
        case .distance(let target):
            let left = target - physics.d
            if target > 750, left <= 500 { once("500", Cox.pick(["Last five hundred. Start building.", "Five hundred to go. Bring it up."])) }
            if target > 375, left <= 250 { once("250", Cox.pick(["Two fifty to go. Lift it!", "Two fifty. Squeeze it up!"])) }
            if target > 150, left <= 100 { once("100", "Last ten strokes. Everything!") }
        case .time(let total):
            let left = total - t
            if left <= total / 2 { once("half", "Halfway. Hold the rhythm.", interrupt: false) }
            if total > 120, left <= 60 { once("60", "One minute left.") }
            if left <= 30 { once("30", "Thirty seconds. Squeeze it up.") }
            if left <= 10 { once("10", "Ten seconds. Empty the tank!") }
        case .open:
            break
        }

        if let rival, t > 6 {
            let gap = physics.d - rival.distance(at: t, finish: eng.piece.finishDistance)
            let sign = gap > 1.5 ? 1 : (gap < -1.5 ? -1 : gapSign)
            if gapSign != 0 && sign != gapSign {
                if sign > 0 {
                    show("You passed \(rival.name)", "Hold that rhythm")
                    cox.say("You've taken \(rival.name). Hold that rhythm.", interrupt: true)
                } else {
                    show("\(rival.capitalizedName) passed you", "Lift the rate for ten")
                    cox.say("\(rival.capitalizedName) has gone past. Lift the rate for ten!", interrupt: true)
                }
            }
            gapSign = sign
            if t - lastReport > 70, t > 40 {
                lastReport = t
                cox.say(abs(gap) < 2 ? "Dead level with \(rival.name)." :
                        gap > 0 ? "Up \(Int(gap.rounded())) metres on \(rival.name)." :
                        "Down \(Int((-gap).rounded())) metres. Lift the rate for ten.")
            }
        }

        if simT - lastStrokeAt > 9 && !stopCalled {
            stopCalled = true
            cox.say(Cox.pick(["Keep it moving. Back on the oars.", "Don't stop now. Pick it up.", "Come on, back to it."]))
        }
    }

    // MARK: - Finish

    func finish(complete: Bool) {
        guard let eng = engine, phase == .rowing else { return }
        var t = eng.t
        var d = physics.d
        if complete, let target = eng.piece.finishDistance {
            if physics.v > 0 { t = max(0, t - (d - target) / physics.v) }
            d = target
        }
        if complete, case .time(let total) = eng.piece.goal { t = total }
        let start = eng.startDate ?? Date()
        var r = RowResult(piece: eng.piece, start: start, end: start.addingTimeInterval(t), duration: t, distance: d,
                          complete: complete, strokes: eng.strokes, averageWatts: eng.averageWatts,
                          splits: eng.splits, samples: eng.samples, saveable: eng.started && t > 10 && d > 50)

        if let rival {
            if complete, let target = eng.piece.finishDistance, let rt = rival.finishTime(for: target) {
                let margin = rt - t
                r.verdictGood = margin > 0
                r.verdict = margin > 0 ? "You beat \(rival.name) by \(String(format: "%.1f", margin)) s."
                                       : "\(rival.capitalizedName) was \(String(format: "%.1f", -margin)) s faster. Next time."
            } else if t > 30 {
                let gap = d - rival.distance(at: t, finish: eng.piece.finishDistance)
                r.verdictGood = gap >= 0
                r.verdict = gap >= 0 ? "You finished \(String(format: "%.1f", gap)) m ahead of \(rival.name)."
                                     : "\(rival.capitalizedName) finished \(String(format: "%.1f", -gap)) m ahead."
            }
        }

        if r.saveable {
            if let previous = Records.best(for: eng.piece, in: history) {
                if eng.piece.isDistance, complete, t < previous.duration {
                    r.recordLine = "New personal best, \(String(format: "%.1f", previous.duration - t)) s faster than before."
                } else if !eng.piece.isDistance, d > previous.distance {
                    r.recordLine = "New personal best, \(Fmt.meters(d - previous.distance)) m further than before."
                }
            } else if complete || !eng.piece.isDistance {
                r.recordLine = "First \(eng.piece.name) on record. This is the ghost to beat next time."
            }
        }

        result = r
        banner = nil
        hint = nil
        phase = .finished
        UIApplication.shared.isIdleTimerDisabled = false
        cox.say(complete ? Cox.pick(["Easy oar. Well rowed.", "And easy. Lovely work.", "Easy there. Good row."]) : "Easy oar.", interrupt: true)
        onFinish?(r)
    }
}
