import Observation
import QuartzCore
import UIKit

struct RacePanel: Equatable {
    enum Tone: Equatable { case neutral, good, bad }
    var title: String
    var value: String
    var tone: Tone
    var me: Double           // 0…1 along the track
    var other: Double?       // the rival's dot, if there is one
}

struct GateChip: Equatable {
    var text: String
    var tone: RacePanel.Tone
}

struct HUDState: Equatable {
    var split: Double = .infinity
    var meters: Double = 0
    var time: Double = 0
    var strokeRate: Double = 0
    var watts: Double = 0
    var heartRate: Int? = nil
    var progress: Double = 0
    var progressText = "Take your first stroke"
    var race: RacePanel? = nil
    var gate: GateChip? = nil
    var flow: Double = 0
    var inZone = false
    var power10: String? = nil
    var power10Calling = false
    var score = 0
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    var medal: String? = nil
}

struct Pop: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let good: Bool
}

/// Who or what you race.
enum Opponent {
    case none
    case rival(Rival)
    case fleet(FleetRace)
    case storm(StormChase)
}

/// Everything needed to start a row.
struct RowSetup {
    var piece: Piece
    var opponent: Opponent = .none
    var history: [PastRow] = []
    var event: SeasonEvent? = nil
    var gates = false
    var challenge: DailyChallenge? = nil
    var journey: Journey? = nil
    var baseSplit: Double = 150
    var condition: Condition = .dawn
    var scenery: Scenery = .river
}

private final class DisplayLinkProxy: NSObject {
    let handler: (CADisplayLink) -> Void
    init(_ handler: @escaping (CADisplayLink) -> Void) { self.handler = handler }
    @objc func tick(_ link: CADisplayLink) { handler(link) }
}

private struct Power10 {
    enum Phase { case idle, call, on }
    var phase = Phase.idle
    var next: Double = 90
    var wait = 0
    var left = 0
    var distance: Double = 0
    var time: Double = 0
    var base: Double = 0
}

/// Runs a row: the frame loop, strokes from taps or the console, rivals, the fleet, the storm,
/// speed gates, intervals, Power 10s, rhythm, points, cox calls and the finish.
@MainActor @Observable
final class RowGame {
    enum Phase: Equatable { case home, countdown, rowing, paused, finished }

    var phase: Phase = .home
    var countdownText = ""
    var eventIntro: SeasonEvent?
    var hud = HUDState()
    var banners: [Banner] = []
    var pop: Pop?
    var result: RowResult?
    var pieceName = ""
    var hint: String?
    var cameraMode = 0 { didSet { world.cameraMode = cameraMode } }

    let world = RiverScene()
    let cox = Cox()
    let sound = SoundEngine()
    /// Ticks at this stroke rate to row along to (0 = off).
    @ObservationIgnored var beatRate = 0
    @ObservationIgnored var onFinish: ((RowResult) -> Void)?

    @ObservationIgnored private weak var link: BluetoothLink?
    @ObservationIgnored private weak var progress: ProgressStore?
    @ObservationIgnored private var physics = RowPhysics()
    @ObservationIgnored private var engine: SessionEngine?
    @ObservationIgnored private var setup: RowSetup?
    @ObservationIgnored private var rival: Rival?
    @ObservationIgnored private var fleet: FleetRace?
    @ObservationIgnored private var storm: StormChase?
    @ObservationIgnored private var intervals: IntervalRunner?
    @ObservationIgnored private var gates: GateCourse?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private var simT: Double = 0
    @ObservationIgnored private var lastStrokeAt: Double = -10
    @ObservationIgnored private var nextDemoStroke: Double = 1
    @ObservationIgnored private var hudClock: Double = 0
    @ObservationIgnored private var consoleBase: Double = 0
    @ObservationIgnored private var ghostNextStroke: Double = 0
    @ObservationIgnored private var crewNextStroke: [Double] = []
    @ObservationIgnored private var crewSigns: [Int] = []
    @ObservationIgnored private var gapSign = 0
    @ObservationIgnored private var calls: Set<String> = []
    @ObservationIgnored private var lastReport: Double = 0
    @ObservationIgnored private var stopCalled = false
    @ObservationIgnored private var countdownToken = 0

    // Per-session game state
    @ObservationIgnored private var score = 0
    @ObservationIgnored private var newAchievements: [Achievement] = []
    @ObservationIgnored private var nextMilestone = 0
    @ObservationIgnored private var sub2Metres: Double = 0
    @ObservationIgnored private var rateRun = 0
    @ObservationIgnored private var rateEma: Double = 0
    @ObservationIgnored private var flow = 0
    @ObservationIgnored private var speedEma: Double = 0
    @ObservationIgnored private var power10 = Power10()
    @ObservationIgnored private var power10Best: Double = 0
    @ObservationIgnored private var stormLevel = 0
    @ObservationIgnored private var caught = false
    @ObservationIgnored private var journeyStart: Double = 0
    @ObservationIgnored private var journeyNext: JourneyStop?
    @ObservationIgnored private var journeyReached: [String] = []
    @ObservationIgnored private var challengeDone = false
    @ObservationIgnored private var spotted: [Animal] = []
    @ObservationIgnored private var cheered = false
    @ObservationIgnored private var nextBeat: Double = 0
    @ObservationIgnored private var musicOn = false
    @ObservationIgnored private var rainOn = false

    init() {
        physics.v = 3.6   // already gliding when the app opens
    }

    var usingConsole: Bool { link?.rowerReady ?? false }

    func attach(link: BluetoothLink, progress: ProgressStore) {
        self.link = link
        self.progress = progress
        link.onStroke = { [weak self] in
            MainActor.assumeIsolated { self?.stroke(fromConsole: true) }
        }
        world.onSighting = { [weak self] s in self?.sighted(s) }
        world.onBottle = { [weak self] msg in self?.bottle(hasMessage: msg) }
        world.onLightning = { [weak self] k in self?.sound.thunder(k) }
        dressBoat()
    }

    /// Puts the player's livery, hat, pet, flag and wake on the boat.
    func dressBoat() {
        guard let progress else { return }
        world.boat.apply(livery: Livery.with(id: progress.state.livery))
        world.boat.setCosmetics(progress.state.cosmetics)
    }

    /// How the river looks on the dock, between rows.
    func setHomeLook(_ condition: Condition, scenery: Scenery) {
        guard phase == .home else { return }
        world.setLook(condition, scenery: scenery)
        rainOn = condition.look.rain
        sound.setRain(rainOn)
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

    func start(_ s: RowSetup) {
        UIApplication.shared.isIdleTimerDisabled = true
        setup = s
        engine = SessionEngine(piece: s.piece)
        pieceName = s.piece.name
        rival = nil
        fleet = nil
        storm = nil
        switch s.opponent {
        case .none: break
        case .rival(let r): rival = r
        case .fleet(let f): fleet = f
        case .storm(let st): storm = st
        }
        intervals = s.piece.intervalSteps.map { IntervalRunner(steps: $0, base: s.baseSplit) }
        gates = s.gates ? GateCourse(piece: s.piece) : nil

        physics.reset()
        lastStrokeAt = simT - 10
        ghostNextStroke = 0
        gapSign = 0
        calls.removeAll()
        lastReport = 0
        stopCalled = false
        consoleBase = link?.consoleDistance ?? 0

        score = 0
        newAchievements = []
        nextMilestone = 0
        sub2Metres = 0
        rateRun = 0
        rateEma = 0
        flow = 0
        speedEma = 0
        power10 = Power10(next: 75 + Double.random(in: 0...45))
        if intervals != nil { power10.next = .infinity }
        power10Best = 0
        stormLevel = 0
        caught = false
        challengeDone = s.challenge == nil
        journeyReached = []
        if let j = s.journey, let p = progress {
            journeyStart = p.state.journeyMeters(j)
            journeyNext = j.nextStop(after: journeyStart)
        } else {
            journeyStart = 0
            journeyNext = nil
        }

        spotted = []
        cheered = false
        nextBeat = 0
        beatRate = UserDefaults.standard.integer(forKey: "beat")
        sound.effectsEnabled = UserDefaults.standard.object(forKey: "effects") as? Bool ?? true
        world.setLook(s.condition, scenery: s.scenery)
        rainOn = s.condition.look.rain
        sound.setRain(rainOn)
        dressBoat()
        world.reset(finishAt: s.piece.finishDistance)
        if let rival { world.ghost.setLabel(rival.tag) }
        world.setCrews(fleet?.boats.map(\.crew) ?? [])
        crewNextStroke = Array(repeating: 0, count: fleet?.boats.count ?? 0)
        crewSigns = Array(repeating: 0, count: fleet?.boats.count ?? 0)
        world.setStorm(storm != nil)
        if storm != nil { cameraMode = 3 } else if cameraMode == 3 { cameraMode = 0 }

        result = nil
        banners = []
        pop = nil
        hint = usingConsole ? "Row when ready. The clock starts on your first stroke." : "Tap anywhere on each stroke"
        hud = HUDState()
        refreshHUD()
        runCountdown(intro: s.event)
    }

    func tap() {
        guard phase == .rowing, !usingConsole else { return }
        stroke(fromConsole: false)
    }

    func pause() {
        guard phase == .rowing || phase == .countdown else { return }
        phase = .paused
        sound.setMusic(strokeRate: 0, level: 0)
    }

    func resume() {
        guard phase == .paused else { return }
        lastFrame = 0
        eventIntro = nil
        phase = .rowing
        startMusic()
    }

    func endSession() {
        if phase == .paused { phase = .rowing }
        finish(complete: false)
    }

    func backToDock() {
        UIApplication.shared.isIdleTimerDisabled = false
        engine = nil
        setup = nil
        rival = nil
        fleet = nil
        storm = nil
        intervals = nil
        gates = nil
        result = nil
        banners = []
        pop = nil
        hint = nil
        eventIntro = nil
        world.reset(finishAt: nil)
        world.ghost.root.isHidden = true
        world.setCrews([])
        world.setStorm(false)
        if cameraMode == 3 { cameraMode = 0 }
        world.sightingsEnabled = false
        stopMusic()
        nextDemoStroke = simT + 1
        phase = .home
        let prefs = Launcher.Prefs.current
        setHomeLook(prefs.resolvedCondition(), scenery: prefs.resolvedScenery(journey: progress?.state.journeyID ?? "gota"))
    }

    func updateResult(_ change: (inout RowResult) -> Void) {
        guard var r = result else { return }
        change(&r)
        result = r
    }

    func cycleCamera() { cameraMode = (cameraMode + 1) % 4 }

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
        world.boat.updateTrail(speed: phase == .paused ? 0 : physics.v)
        world.sightingsEnabled = phase == .rowing && (engine?.started ?? false)

        if phase == .rowing, var eng = engine {
            let completed = eng.advance(dt: dt, distance: physics.d, watts: currentWatts)
            engine = eng
            for segment in completed { splitDone(segment, engine: eng) }
            if eng.started { sessionTick(dt, eng) }
            if phase == .rowing, eng.isComplete(distance: physics.d) { finish(complete: true) }
        }

        let t = (engine?.started ?? false) ? engine!.t : 0
        let racing = phase != .home && engine != nil
        var ghostDistance: Double?
        if racing, let rival, let eng = engine {
            let gd = rival.distance(at: t, finish: eng.piece.finishDistance)
            ghostDistance = gd
            let moving = phase == .rowing && eng.started && rival.distance(at: t + 0.5, finish: eng.piece.finishDistance) - gd > 0.25
            if moving && simT >= ghostNextStroke {
                let period = 60 / max(rival.strokeRate, 16)
                ghostNextStroke = simT + period
                world.ghost.stroke(recovery: period - RowPhysics.driveTime)
            }
        }
        if racing, let fleet {
            var positions: [(distance: Double, lane: Double)] = []
            for i in fleet.boats.indices {
                let d = fleet.distance(i, at: t)
                positions.append((d, fleet.boats[i].lane))
                let moving = phase == .rowing && (engine?.started ?? false) && d < (fleet.finish ?? .infinity)
                if moving, i < crewNextStroke.count, simT >= crewNextStroke[i], i < world.crewBoats.count {
                    let period = 60 / fleet.boats[i].strokeRate
                    crewNextStroke[i] = simT + period
                    world.crewBoats[i].stroke(recovery: period - RowPhysics.driveTime)
                }
            }
            world.updateCrews(positions, time: simT, dt: dt)
        }
        if let storm {
            let dark = StormChase.darkness(gap: storm.gap(physics.d))
            world.applyStorm(dark, dt: dt, time: simT, wallAt: storm.position)
            let wet = (setup?.condition.look.rain ?? false) || dark > 0.4
            if wet != rainOn {
                rainOn = wet
                sound.setRain(wet)
            }
        }
        if let gates { world.syncGates(gates.gates, distance: physics.d, time: simT) }
        world.update(dt: dt, time: simT, distance: physics.d, ghostDistance: ghostDistance)

        if phase == .rowing, beatRate > 0, engine?.started ?? false, simT >= nextBeat {
            nextBeat = simT + 60 / Double(beatRate)
            sound.tick()
        }

        hudClock += dt
        if hudClock >= 0.1, phase == .rowing || phase == .countdown {
            hudClock = 0
            refreshHUD()
            checkChallenge(finished: false)
            if musicOn { sound.setMusic(strokeRate: hud.strokeRate, level: musicLevel()) }
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
        if phase == .rowing { sound.splash(volume: 0.22) }
        guard phase == .rowing, var eng = engine else { return }
        eng.stroke(at: simT)
        engine = eng
        stopCalled = false
        if eng.strokes == 6 { hint = nil }

        let spm = usingConsole ? (link?.strokeRate ?? 0) : eng.strokeRate(now: simT)
        if spm >= 30 {
            rateRun += 1
            if rateRun >= 20 { unlock("rate30") }
        } else {
            rateRun = 0
        }
        rhythm(rate: spm > 0 ? spm : (gap > 0.6 && gap < 6 ? 60 / gap : 0))
        power10Stroke()
    }

    /// Rhythm flow: strokes at a steady rate fill the bar; a ragged one knocks it back.
    private func rhythm(rate r: Double) {
        guard r > 0 else { return }
        if rateEma == 0 { rateEma = r }
        let dev = abs(r - rateEma) / rateEma
        rateEma += (r - rateEma) * 0.25
        let f0 = flow
        if dev < 0.06 { flow = min(20, flow + 1) } else if dev > 0.15 { flow = max(0, flow - 4) }
        if flow >= 20 { score += 3 } else if flow >= 10 { score += 1 }
        if f0 < 10 && flow >= 10 { cox.say(Cox.pick(["Lovely rhythm. Keep it there.", "That's it. Nice and steady."])) }
        if f0 < 20 && flow >= 20 {
            cox.say(Cox.pick(["That is the zone. Hold it!", "In the zone. Beautiful."]))
            unlock("zone")
        }
        if f0 >= 10 && flow < 10 { cox.say("Rhythm slipped. Find it again.") }
    }

    // MARK: - Power 10

    private func power10Stroke() {
        switch power10.phase {
        case .call:
            power10.wait -= 1
            if power10.wait <= 0 {
                power10.phase = .on
                power10.left = 10
                power10.distance = 0
                power10.time = 0
                cox.say(Cox.pick(["Go!", "Now!", "Up!"]), interrupt: true)
            }
        case .on:
            power10.left -= 1
            if power10.left == 5 { cox.say(Cox.pick(["Five more.", "Halfway, five more.", "Keep going, five!"])) }
            if power10.left <= 0 { endPower10() }
        case .idle:
            break
        }
    }

    private func startPower10() {
        power10.phase = .call
        power10.wait = 1
        power10.base = max(speedEma, 0.5)
        cox.say(Cox.pick(["Power ten, on the next one.", "Give me ten. Next stroke.", "Ten big ones, on this one."]), interrupt: true)
    }

    private func endPower10() {
        let avg = power10.time > 0 ? power10.distance / power10.time : 0
        let gain = avg / power10.base - 1
        power10Best = max(power10Best, gain)
        power10.phase = .idle
        power10.next = (engine?.t ?? 0) + 90 + Double.random(in: 0...60)
        if gain > 0.03 {
            let pts = min(250, 50 + Int((gain * 1000).rounded()))
            addScore(pts, label: "Power 10 · +\(Int((gain * 100).rounded()))% speed")
            cox.say(Cox.pick(["Good ten! ", "That moved it! ", "Lovely! "]) + "\(Int((gain * 100).rounded())) percent faster. " +
                    Cox.pick(["Settle.", "And settle.", "Back to rhythm."]), interrupt: true)
            if gain >= 0.08 { unlock("p10") }
        } else {
            show("Power 10 done", "Settle into your rhythm")
            cox.say(Cox.pick(["Settle. Back to rhythm.", "Good. Settle it down.", "And settle. Long and strong."]), interrupt: true)
        }
    }

    // MARK: - Per-frame session logic

    private func sessionTick(_ dt: Double, _ eng: SessionEngine) {
        let t = eng.t, d = physics.d

        while nextMilestone < Achievement.distanceMilestones.count, d >= Achievement.distanceMilestones[nextMilestone].0 {
            unlock(Achievement.distanceMilestones[nextMilestone].1)
            nextMilestone += 1
        }
        if physics.v > 500.0 / 120 {
            sub2Metres += physics.v * dt
            if sub2Metres >= 250 { unlock("sub2") }
        } else {
            sub2Metres = 0
        }
        speedEma += (physics.v - speedEma) * min(1, dt / 15)

        // Power 10
        if power10.phase == .on {
            power10.distance += physics.v * dt
            power10.time += dt
        } else if power10.phase == .idle, t >= power10.next, simT - lastStrokeAt < 3,
                  !(eng.piece.finishDistance.map { $0 - d < 300 } ?? false) {
            startPower10()
        }

        rivalCalls(t)
        fleetCalls(t)
        journeyTick(d)
        raceCalls(eng)
        gateTick(t, d)
        intervalTick(t, d)
        guard phase == .rowing else { return }
        stormTick(dt, t, d)
    }

    private func rivalCalls(_ t: Double) {
        guard let rival, let eng = engine, t > 6 else { return }
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

    private func fleetCalls(_ t: Double) {
        guard let fleet, t > 3 else { return }
        let taunts = setup?.event?.taunts
        for i in fleet.boats.indices where i < crewSigns.count {
            let g = physics.d - fleet.distance(i, at: t)
            let sign = g > 2 ? 1 : (g < -2 ? -1 : crewSigns[i])
            if crewSigns[i] != 0 && sign != crewSigns[i] {
                let name = fleet.boats[i].crew.name
                if sign > 0 {
                    let pos = fleet.standing(me: physics.d, at: t).position
                    addScore(100, label: "You passed \(name)")
                    sound.pop()
                    cox.say("That's \(name). Position \(pos).", interrupt: true)
                    if let taunts { cox.rivalSay(Cox.pick(taunts.behind)) }
                } else {
                    show("\(name) passed you", "Hold them off")
                    cox.say("\(name) coming through. Hold them off!", interrupt: true)
                    if let taunts { cox.rivalSay(Cox.pick(taunts.ahead)) }
                }
            }
            crewSigns[i] = sign
        }
    }

    private func journeyTick(_ d: Double) {
        guard let stop = journeyNext, let j = setup?.journey, journeyStart + d >= stop.meters else { return }
        show("Reached \(stop.name)", stop.fact)
        sound.chime()
        cox.say("You have reached \(stop.name).", interrupt: true)
        score += 75
        journeyReached.append(stop.name)
        journeyNext = j.nextStop(after: stop.meters)
    }

    private func gateTick(_ t: Double, _ d: Double) {
        guard var course = gates, let s = setup else { return }
        let estimate = t > 40 && speedEma > 0.6 ? 500 / speedEma : 0
        let events = course.update(t: t, d: d, baseSplit: estimate > 0 ? estimate : s.baseSplit)
        gates = course
        for e in events {
            switch e {
            case .opened(let g):
                if g.gold { cox.say("Gold gate! \(Fmt.spokenSplit(g.target)) or better.", interrupt: true) }
                else if course.attempts == 0 { cox.say("Speed gate. Beat \(Fmt.spokenSplit(g.target)) to the line.") }
            case .hit(let g, _, let combo):
                let mult = min(combo, 5)
                if case .hit(let pts) = g.state { score += pts; popUp("+\(pts)" + (mult > 1 ? "  ×\(mult)" : ""), good: true) }
                sound.ding(gold: g.gold)
                if combo >= 5 { unlock("combo5") }
                if combo >= 3 { cox.say("\(combo) in a row!") } else if g.gold { cox.say("Gold!") }
            case .missed(_, let split):
                popUp("Missed · \(Fmt.split(split))", good: false)
                sound.thud()
            }
        }
    }

    private func intervalTick(_ t: Double, _ d: Double) {
        guard var runner = intervals else { return }
        let events = runner.update(t: t, d: d)
        intervals = runner
        for e in events {
            switch e {
            case .workStarted(let rep, let of, let target, let step):
                let what = step.meters.map { "\(Int($0)) metres" } ?? Self.spokenRest(step.seconds ?? 0)
                cox.say((rep == of ? "Last one! " : "Rep \(rep). ") + "\(what), target \(Fmt.spokenSplit(target)). Go!", interrupt: true)
            case .restStarted(let seconds, _):
                cox.say(Cox.pick(["Easy. Breathe.", "And rest. Good work.", "Paddle light. Recover."]) + " " + Self.spokenRest(seconds), interrupt: true)
            case .halfway(let onTarget):
                cox.say("Halfway. " + (onTarget ? "On target. Hold it." : "Off target. Squeeze it up."))
            case .lastHundred:
                cox.say(Cox.pick(["Last hundred! Empty it!", "Hundred to go. Lift!"]), interrupt: true)
            case .lastTenSeconds:
                cox.say("Ten seconds! Everything!", interrupt: true)
            case .restEnding:
                cox.say("Ten seconds. Sit ready.", interrupt: true)
            case .restBeep:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                sound.tick()
            case .repDone(let r):
                let n = runner.reps.count
                if r.hit { score += 100 }
                popUp("Rep \(n) · \(Fmt.clock(r.split, tenths: true))", good: r.hit)
                show("Rep \(n)" + (r.hit ? " on target" : " done"), "\(Fmt.clock(r.split, tenths: true)) /500 m · target \(Fmt.clock(r.target))")
            case .finished:
                if !runner.reps.isEmpty, runner.reps.allSatisfy(\.hit) { unlock("ivall") }
                finish(complete: true)
                return
            }
        }
    }

    private static func spokenRest(_ t: Double) -> String {
        let s = Int(t)
        if s < 60 { return "\(s) seconds" }
        if s % 60 != 0 { return "\(s / 60) minute \(s % 60)" }
        return "\(s / 60) minute" + (s >= 120 ? "s" : "")
    }

    private func stormTick(_ dt: Double, _ t: Double, _ d: Double) {
        guard var st = storm else { return }
        st.advance(dt: dt, t: t)
        storm = st
        let gap = st.gap(d)
        let level = StormChase.level(gap: gap)
        if level > stormLevel {
            cox.say(["", "Storm closing. A hundred metres behind.", "Fifty metres! Lift the rate!", "It is right behind you! Everything!"][level], interrupt: true)
        } else if level == 0, stormLevel > 0, gap > 120 {
            cox.say("You are pulling away. Hold that.")
        }
        if level > stormLevel || (level < stormLevel && (level > 0 || gap > 120)) { stormLevel = level }
        if t >= 300 { unlock("storm5") }
        if gap <= 0 {
            caught = true
            cox.say("The storm got you!", interrupt: true)
            finish(complete: true)
        }
    }

    // MARK: - Points, milestones and the daily challenge

    private func addScore(_ n: Int, label: String? = nil) {
        guard n > 0 else { return }
        score += n
        if let label { show(label, "+\(n) points") }
    }

    private func unlock(_ id: String) {
        guard let progress, progress.unlock(id), let a = Achievement.with(id: id) else { return }
        newAchievements.append(a)
        show(a.name, a.detail, medal: a.code)
        sound.chime()
        score += 50
        cox.say(Cox.pick(["Milestone. ", "Nice, that's ", "New medal: "]) + a.name + ".")
    }

    private func snapshot() -> ChallengeSnapshot {
        let eng = engine
        var position: Int?
        if let fleet, let eng {
            position = fleet.finalPosition(myTime: eng.t, myDistance: physics.d,
                                           completedDistance: eng.piece.finishDistance.map { physics.d >= $0 } ?? false)
        }
        return ChallengeSnapshot(distance: physics.d, time: eng?.t ?? 0, gatesHit: gates?.hits ?? 0, bestCombo: gates?.bestCombo ?? 0,
                                 splits: eng?.splits ?? [], power10Best: power10Best, fleetPosition: position, storm: storm != nil)
    }

    private func checkChallenge(finished: Bool, position: Int? = nil) {
        guard !challengeDone, let c = setup?.challenge, engine?.started ?? false, let progress, !progress.challengeDoneToday else { return }
        var snap = snapshot()
        if let position { snap.fleetPosition = position }
        guard c.check(snap, finished) else { return }
        challengeDone = true
        progress.update { $0.challenges[DailyChallenge.dayKey()] = true }
        score += 300
        show("Daily challenge complete", "\(c.text) · +300", medal: "★")
        sound.chime()
        cox.say("Daily challenge complete!", interrupt: true)
    }

    // MARK: - HUD

    private func refreshHUD() {
        guard let eng = engine else { return }
        var h = HUDState()
        let d = physics.d, t = eng.t
        h.split = physics.v > 0.3 ? 500 / physics.v : .infinity
        h.meters = d
        h.time = t
        h.strokeRate = usingConsole ? (link?.strokeRate ?? 0) : eng.strokeRate(now: simT)
        h.watts = currentWatts
        h.heartRate = link?.heartRate
        h.score = score
        if let runner = intervals {
            h.progress = runner.progress(t: t, d: d)
            h.progressText = eng.started ? runner.remainingText(t: t, d: d) : eng.progressText(distance: d, connected: usingConsole)
        } else if let storm {
            h.progress = clamp(storm.gap(d) / 200, 0, 1)
            h.progressText = eng.progressText(distance: d, connected: usingConsole)
        } else {
            h.progress = eng.progress(distance: d)
            h.progressText = eng.progressText(distance: d, connected: usingConsole)
        }
        if simT - lastStrokeAt > 6 { flow = 0 }
        h.flow = Double(flow) / 20
        h.inZone = flow >= 20
        switch power10.phase {
        case .idle: break
        case .call: h.power10 = "Power 10 · next stroke"; h.power10Calling = true
        case .on: h.power10 = "Power 10 · \(power10.left)"
        }
        h.race = racePanel(t: t, d: d)
        if let g = gates {
            if let live = g.live {
                let cur = g.liveSplit(t: t, d: d)
                h.gate = GateChip(text: "Beat \(Fmt.clock(live.target)) · now \(Fmt.split(cur ?? .infinity))",
                                  tone: (cur ?? .infinity) <= live.target ? .good : .bad)
            } else {
                var text = "Gates \(g.hits)/\(g.attempts)"
                if g.combo > 1 { text += " · ×\(min(g.combo, 5)) combo" }
                else if let next = g.next { text += " · next in \(Fmt.meters(next.d - d)) m" }
                h.gate = GateChip(text: text, tone: .neutral)
            }
        }
        hud = h
    }

    private func track(_ gap: Double) -> (me: Double, other: Double) {
        let span = max(20, abs(gap) * 1.4)
        return (clamp(0.5 + gap / span * 0.45, 0.04, 0.96), clamp(0.5 - gap / span * 0.45, 0.04, 0.96))
    }

    private func signed(_ gap: Double) -> String { (gap >= 0 ? "+" : "−") + String(format: "%.1f m", abs(gap)) }

    private func racePanel(t: Double, d: Double) -> RacePanel? {
        let pts = score > 0 ? " · \(Fmt.meters(Double(score))) pts" : ""
        if let runner = intervals, let step = runner.current {
            let el = t - runner.t0, dd = d - runner.d0
            if step.kind == .work {
                let target = runner.target(step)
                let cur = runner.currentSplit(t: t, d: d)
                let frac = step.meters.map { dd / $0 } ?? el / max(1, step.seconds ?? 1)
                return RacePanel(title: "Rep \(runner.repNumber) of \(runner.repCount) · target \(Fmt.clock(target))" + pts,
                                 value: Fmt.split(cur ?? .infinity),
                                 tone: cur == nil ? .neutral : (cur! <= target ? .good : .bad),
                                 me: clamp(0.04 + frac * 0.92, 0.04, 0.96), other: 0.96)
            }
            let total = step.seconds ?? 1
            return RacePanel(title: "Rest · next up: rep \(runner.repNumber + 1) of \(runner.repCount)" + pts,
                             value: Fmt.clock(max(0, total - el)), tone: .neutral,
                             me: clamp(0.04 + el / total * 0.92, 0.04, 0.96), other: 0.96)
        }
        if let storm {
            let gap = storm.gap(d)
            return RacePanel(title: "Outrun the storm · distance to the storm" + pts, value: "\(Int(max(0, gap))) m",
                             tone: gap > 100 ? .good : (gap < 50 ? .bad : .neutral),
                             me: clamp(0.12 + gap / 200 * 0.8, 0.06, 0.96), other: 0.04)
        }
        if let fleet {
            let s = fleet.standing(me: d, at: t)
            let gap = s.nextName != nil ? -s.nextGap : (s.behindGap ?? 0)
            let p = track(gap)
            let title = fleet.isDuel ? "Duel with \(fleet.boats[0].crew.name) · \(s.position == 1 ? "you lead" : "chasing")"
                                     : "Fleet race · position \(s.position) of \(fleet.total)"
            return RacePanel(title: title + pts, value: signed(gap), tone: s.nextName != nil ? .bad : .good, me: p.me, other: p.other)
        }
        if let rival, let eng = engine {
            let gap = d - rival.distance(at: t, finish: eng.piece.finishDistance)
            let p = track(gap)
            return RacePanel(title: "Racing \(rival.title)" + pts, value: signed(gap),
                             tone: abs(gap) < 0.5 ? .neutral : (gap > 0 ? .good : .bad), me: p.me, other: p.other)
        }
        return nil
    }

    // MARK: - Countdown

    private func runCountdown(intro event: SeasonEvent?) {
        countdownToken += 1
        let token = countdownToken
        phase = .countdown
        countdownText = ""
        eventIntro = event
        let steps: [(text: String, seconds: Double)] = [("Sit ready", 1.3), ("Attention", 1.3), ("Row!", 0.7)]
        Task { [weak self] in
            if let event {
                self?.cox.say("Event \(event.number). \(event.name). \(event.goalText).", interrupt: true)
                if let taunts = event.taunts {
                    try? await Task.sleep(for: .seconds(0.9))
                    guard let self, self.countdownToken == token else { return }
                    self.cox.rivalSay(taunts.start)
                }
                try? await Task.sleep(for: .seconds(event.taunts == nil ? 3.6 : 5.9))
                guard let self, self.countdownToken == token, self.phase == .countdown else { return }
                self.eventIntro = nil
            }
            for (i, step) in steps.enumerated() {
                guard let self, self.countdownToken == token, self.phase == .countdown else { return }
                self.countdownText = step.text
                self.cox.say(i == 2 ? Cox.pick(["Go!", "Row!", "Attention. Go!"]) : step.text, interrupt: true)
                if i == 2 { self.sound.horn() }
                try? await Task.sleep(for: .seconds(step.seconds))
            }
            guard let self, self.countdownToken == token, self.phase == .countdown else { return }
            self.countdownText = ""
            self.phase = .rowing
            self.startMusic()
        }
    }

    // MARK: - Calls

    private func show(_ title: String, _ detail: String, medal: String? = nil) {
        let b = Banner(title: title, detail: detail, medal: medal)
        banners.append(b)
        if banners.count > 3 { banners.removeFirst(banners.count - 3) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.4))
            self?.banners.removeAll { $0.id == b.id }
        }
    }

    private func popUp(_ text: String, good: Bool) {
        let p = Pop(text: text, good: good)
        pop = p
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.pop?.id == p.id { self?.pop = nil }
        }
    }

    private func splitDone(_ segment: Double, engine eng: SessionEngine) {
        guard intervals == nil else { return }    // intervals call their own reps
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
            if !cheered, left < 130, left > 0 {
                cheered = true
                sound.applause()
                cox.say(Cox.pick(["Hear that crowd? Bring it home!", "The crowd is up! Last push!"]), interrupt: true)
            }
        case .time(let total):
            let left = total - t
            if left <= total / 2 { once("half", "Halfway. Hold the rhythm.", interrupt: false) }
            if total > 120, left <= 60 { once("60", "One minute left.") }
            if left <= 30 { once("30", "Thirty seconds. Squeeze it up.") }
            if left <= 10 { once("10", "Ten seconds. Empty the tank!") }
        case .open, .storm, .intervals:
            break
        }

        let resting = intervals?.current?.kind == .rest
        if simT - lastStrokeAt > 9 && !stopCalled && !resting {
            stopCalled = true
            cox.say(Cox.pick(["Keep it moving. Back on the oars.", "Don't stop now. Pick it up.", "Come on, back to it."]))
        }
    }

    // MARK: - Wildlife, bottles and music

    private func sighted(_ s: Sighting) {
        guard phase == .rowing, let progress else { return }
        let a = s.animal
        let first = (progress.state.wildlife[a.rawValue] ?? 0) == 0
        progress.update { $0.wildlife[a.rawValue, default: 0] += 1 }
        if !spotted.contains(a) { spotted.append(a) }
        if first {
            score += a.points
            show("New in your field guide: \(a.name)", "\(a.rarity) · +\(a.points)", medal: "+")
            sound.chime()
            cox.say(Cox.pick(["\(a.name) on the \(s.sideName)! A new one for the field guide.",
                              "Look, on the \(s.sideName). \(a.name)! That one is new."]), interrupt: true)
            if progress.state.animalsSeen == Animal.allCases.count { unlock("wild8") }
        } else if a.rarity != "Common" {
            score += a.points / 4
            cox.say(Cox.pick(["\(a.name) on the \(s.sideName).", "Look, \(a.name.lowercased()) on the \(s.sideName) bank."]))
        }
    }

    private func bottle(hasMessage: Bool) {
        guard phase == .rowing, let progress else { return }
        sound.plink()
        score += 20
        popUp("+20", good: true)
        guard hasMessage else { return }
        let fact = progress.nextFact()
        show("Message in a bottle", fact)
        cox.say("Message in a bottle. " + fact)
    }

    private func startMusic() {
        guard UserDefaults.standard.object(forKey: "music") as? Bool ?? true else { return }
        musicOn = true
        sound.musicEnabled = true
        sound.startMusic()
    }

    private func stopMusic() {
        guard musicOn else { return }
        musicOn = false
        sound.stopMusic()
    }

    /// 0 easy … 3 flat out: how much of the band is playing.
    private func musicLevel() -> Int {
        guard phase == .rowing, let eng = engine, eng.started, simT - lastStrokeAt <= 5 else { return 0 }
        if let runner = intervals { return runner.current?.kind == .work ? 3 : 0 }
        let nearFinish = eng.piece.finishDistance.map { $0 - physics.d < 250 } ?? false
        if power10.phase == .on || nearFinish || (storm != nil && world.stormK > 0.6) { return 3 }
        let base = setup?.baseSplit ?? 150
        let split = physics.v > 0.3 ? 500 / physics.v : 999
        return split < base - 1 || gates?.live != nil ? 2 : 1
    }

    // MARK: - Finish

    func finish(complete: Bool) {
        guard let eng = engine, let s = setup, phase == .rowing else { return }
        let piece = eng.piece
        var t = eng.t
        var d = physics.d
        if complete, let target = piece.finishDistance {
            if physics.v > 0 { t = max(0, t - (d - target) / physics.v) }
            d = target
        }
        if complete, case .time(let total) = piece.goal { t = total }
        let start = eng.startDate ?? Date()
        var r = RowResult(piece: piece, start: start, end: start.addingTimeInterval(t), duration: t, distance: d,
                          complete: complete, strokes: eng.strokes, averageWatts: eng.averageWatts,
                          splits: eng.splits, samples: eng.samples, saveable: eng.started && t > 10 && d > 50)
        var margin: Double?
        var position: Int?

        if let rival {
            if complete, let target = piece.finishDistance, let rt = rival.finishTime(for: target) {
                let m = rt - t
                margin = m
                r.verdictGood = m > 0
                r.verdict = m > 0 ? "You beat \(rival.name) by \(String(format: "%.1f", m)) s."
                                  : "\(rival.capitalizedName) was \(String(format: "%.1f", -m)) s faster. Next time."
                if m > 0 { unlock("ghost") }
            } else if t > 30 {
                let gap = d - rival.distance(at: t, finish: piece.finishDistance)
                r.verdictGood = gap >= 0
                r.verdict = gap >= 0 ? "You finished \(String(format: "%.1f", gap)) m ahead of \(rival.name)."
                                     : "\(rival.capitalizedName) finished \(String(format: "%.1f", -gap)) m ahead."
                if gap > 0 && (complete || piece.goal == .open) { unlock("ghost") }
            }
            if r.verdict != nil, r.verdictGood { score += 150 }
        }

        if let fleet {
            let pos = fleet.finalPosition(myTime: t, myDistance: d, completedDistance: complete && piece.isDistance)
            position = pos
            let ordinal = ["1st", "2nd", "3rd", "4th", "5th", "6th", "7th"][min(pos, 7) - 1]
            if fleet.isDuel {
                let name = fleet.boats[0].crew.name
                if complete, let target = piece.finishDistance { margin = fleet.finishTime(0, target: target) - t }
                let by = margin.map { String(format: " by %.1f s", abs($0)) } ?? ""
                r.verdictGood = pos == 1
                r.verdict = pos == 1 ? "You beat \(name)\(by)." : "\(name) won\(by). Go again."
            } else {
                r.verdictGood = pos <= 3
                r.verdict = pos == 1 ? "You won the fleet race. Head of the river." : "You finished \(ordinal) of \(fleet.total)."
                if pos == 1 && t > 60 { unlock("fleet1") }
            }
            if t > 60, pos <= 3 { score += [300, 200, 100][pos - 1] }
        }

        if let runner = intervals, !runner.reps.isEmpty {
            r.reps = runner.reps
            let hit = runner.reps.filter(\.hit).count
            r.verdictGood = hit == runner.reps.count
            r.verdict = "You hit \(hit) of \(runner.reps.count) targets, averaging \(Fmt.clock(r.averageWorkSplit ?? 0, tenths: true)) per 500 m on the hard pieces."
        }

        if let storm {
            r.caughtByStorm = caught
            r.verdictGood = !caught
            r.verdict = caught ? "The storm caught you after \(Fmt.meters(d)) m." : "You stopped \(Fmt.meters(max(0, storm.gap(d)))) m clear of the storm."
            score += Int(d / 5)
        }
        if complete { score += 100 }

        checkChallenge(finished: true, position: position)
        r.challengeText = s.challenge?.text
        r.challengeDone = challengeDone && s.challenge != nil

        if let g = gates {
            r.gatesHit = g.hits
            r.gatesTried = g.attempts
            r.bestCombo = g.bestCombo
        }

        if let ev = s.event, let progress {
            let previous = progress.state.season[ev.id] ?? 0
            let perf = Season.Performance(complete: complete, margin: margin, fleetPosition: position, gatesHit: gates?.hits ?? 0,
                                          minutes: t / 60, repsHit: intervals?.reps.filter(\.hit).count ?? 0)
            let outcome = Season.outcome(ev, perf, previous: previous, stars: progress.state.season)
            progress.update { $0.season[ev.id] = max(previous, outcome.stars) }
            if outcome.stars > previous { score += (outcome.stars - previous) * 150 }
            let stars = progress.state.season
            if Season.events.allSatisfy({ (stars[$0.id] ?? 0) > 0 }) { unlock("season1") }
            if Season.events.allSatisfy({ (stars[$0.id] ?? 0) == 3 }) { unlock("season3") }
            r.event = outcome
            if let taunts = ev.taunts {
                let line = position == 1 ? taunts.lose : taunts.win
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3.2))
                    self?.cox.rivalSay(line)
                }
            }
        }

        if r.saveable {
            r.recordLine = recordLine(for: r, history: s.history)
            if r.recordLine?.hasPrefix("New") ?? false { unlock("pb") }
            if let progress {
                progress.update {
                    $0.lifetime += d
                    $0.markDay()
                }
                if progress.state.streak() >= 3 { unlock("streak3") }
                if progress.state.lifetime >= 42195 { unlock("life42") }
                if let j = s.journey {
                    let before = progress.state.journeyMeters(j)
                    progress.update { $0.journeys[j.id] = min(j.meters, before + d) }
                    let line = JourneyLine(journey: j, before: before, after: progress.state.journeyMeters(j), reached: journeyReached)
                    if line.complete { unlock("voyage") }
                    r.journey = line
                }
                let before = progress.state.xp
                let gain = score + Int(d / 10)
                progress.update {
                    $0.xp += gain
                    $0.coins += score
                }
                r.xp = XPGain(gain: gain, before: before, after: before + gain)
            }
        }
        r.score = score
        r.newAchievements = newAchievements
        r.spotted = spotted

        result = r
        banners = []
        pop = nil
        hint = nil
        eventIntro = nil
        phase = .finished
        world.sightingsEnabled = false
        stopMusic()
        if r.isCelebration {
            sound.applause()
            world.celebrate()
        }
        UIApplication.shared.isIdleTimerDisabled = false
        cox.say(complete ? Cox.pick(["Easy oar. Well rowed.", "And easy. Lovely work.", "Easy there. Good row."]) : Cox.pick(["Easy oar.", "And easy."]), interrupt: true)
        if let xp = r.xp, xp.leveledUp {
            let level = xp.levelAfter
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.9))
                self?.cox.say("Level up! Level \(level). \(Levels.rank(level)).")
            }
        }
        onFinish?(r)
    }

    private func recordLine(for r: RowResult, history: [PastRow]) -> String? {
        let piece = r.piece
        if let prev = Records.best(for: piece, in: history) {
            if piece.intervalSteps != nil {
                if r.complete, let mine = r.averageWorkSplit, let theirs = prev.averageWorkSplit, mine < theirs {
                    return "New best average, \(String(format: "%.1f", theirs - mine)) s faster per 500 m."
                }
            } else if piece.isDistance {
                if r.complete, r.duration < prev.duration {
                    return "New personal best, \(String(format: "%.1f", prev.duration - r.duration)) s faster than before."
                }
            } else if r.distance > prev.distance {
                return "New personal best, \(Fmt.meters(r.distance - prev.distance)) m further than before."
            }
            return nil
        }
        guard r.complete || !(piece.isDistance || piece.intervalSteps != nil) else { return nil }
        if piece.isStorm { return "First storm run on record. Beat \(Fmt.meters(r.distance)) m next time." }
        if piece.intervalSteps != nil, let avg = r.averageWorkSplit {
            return "First \(piece.name) on record. Beat an average of \(Fmt.clock(avg, tenths: true)) next time."
        }
        return "First \(piece.name) on record. This is the ghost to beat next time."
    }
}
