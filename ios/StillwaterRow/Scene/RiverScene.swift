import SceneKit
import UIKit
import simd

/// Shared geometry for scenery, so each stretch of river flattens into a few draw calls.
@MainActor
private enum Props {
    static let spruceCones: [SCNGeometry] = [0x1f3a24, 0x24402a, 0x2b4a2f, 0x1c3322].map { (hex: UInt32) -> SCNGeometry in
        let g = SCNCone(topRadius: 0, bottomRadius: 1, height: 1)
        g.radialSegmentCount = 7
        g.materials = [Palette.lambert(hex)]
        return g
    }
    static let leaves: [SCNGeometry] = [0xd9a032, 0xc9782a, 0xb8862e, 0xe0b84a, 0xa9552a].map { (hex: UInt32) -> SCNGeometry in
        let g = SCNSphere(radius: 1)
        g.segmentCount = 7
        g.materials = [Palette.lambert(hex)]
        return g
    }
    static let trunk: SCNGeometry = {
        let g = SCNCylinder(radius: 0.6, height: 1)
        g.radialSegmentCount = 5
        g.materials = [Palette.lambert(0x4a3a2b)]
        return g
    }()
    static let birchTrunk: SCNGeometry = {
        let g = SCNCylinder(radius: 0.6, height: 1)
        g.radialSegmentCount = 5
        g.materials = [Palette.lambert(0xe6e1d6)]
        return g
    }()
    static let buoyOrange: SCNGeometry = buoy(0xe8743a)
    static let buoyWhite: SCNGeometry = buoy(0xf4f2ec)
    static let pole: SCNGeometry = {
        let g = SCNCylinder(radius: 0.12, height: 1)
        g.radialSegmentCount = 6
        g.materials = [Palette.lambert(0xece8df)]
        return g
    }()

    static func buoy(_ hex: UInt32) -> SCNGeometry {
        let g = SCNSphere(radius: 0.2)
        g.segmentCount = 8
        g.materials = [Palette.lambert(hex)]
        return g
    }
}

/// The world: sky, water, endless procedural banks, your boat, the ghost and the camera.
@MainActor
final class RiverScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let boat = BoatNode(style: .player)
    let ghost = BoatNode(style: .ghost)
    var cameraMode = 0 {
        // Turning round to look back is a cut, not a swing through the boat.
        didSet { if (oldValue == 3) != (cameraMode == 3) { cameraPlaced = false } }
    }
    private var camYaw: Float = 0

    // MARK: Hooks for the game

    /// A lightning flash just fired; the value is the storm's strength 0…1 (play thunder).
    var onLightning: ((Double) -> Void)?
    /// An animal came into view. Fires once per animal, only while `sightingsEnabled`.
    var onSighting: ((Sighting) -> Void)?
    /// The boat picked up a bottle. Only while `sightingsEnabled`.
    var onBottle: ((_ hasMessage: Bool) -> Void)?
    /// Turn on during a started row. Animals and bottles passed while off are used up silently.
    var sightingsEnabled = false

    // MARK: World state

    let water = SCNNode()
    let waterMaterial = SCNMaterial()
    let ambientLight = SCNLight()
    let sunLight = SCNLight()
    let fillLight = SCNLight()
    let sunNode = SCNNode()
    let skyDome = SCNNode()
    let skyMaterial = SCNMaterial()
    var rain = SCNParticleSystem()
    var look = Condition.dawn.look
    var scenery: Scenery = .river

    var crewBoats: [BoatNode] = []
    var gateNodes: [Int: GateNode] = [:]
    var stormWall: SCNNode?
    var stormK: Double = 0
    var flashT: Double = 0
    var nextBolt: Double = 0
    var appliedStorm: Double = 0
    var appliedFlash: Double = 0

    var chunks: [Int: RiverChunk] = [:]
    var seenWild = Set<Int>()
    var takenBottles = Set<Int>()
    private var finishAt: Int = 0

    // Night, birds, fireworks (see Atmosphere.swift).
    let boatLamp = SCNNode()
    let boatLampLight = SCNLight()
    let lanternLights = [SCNNode(), SCNNode()]
    let birds = SCNNode()
    var birdWings: [(node: SCNNode, sign: Float, phase: Double)] = []
    var birdVelocity = SIMD3<Float>(0, 0, 0)
    var birdLife: Double = 0
    var birdNext: Double = 8
    var fireworkTemplate = SCNParticleSystem()
    var fireworkHolders: [SCNNode] = []
    var fireworksStart: Double?
    var fireworksFired = 0
    var lastTime: Double = 0

    private var ripples: [(node: SCNNode, age: Double, size: Double)] = []
    private var rippleIndex = 0
    private var camPos = SIMD3<Float>(0, 4, 12)
    private var camLook = SIMD3<Float>(0, 0, 0)
    private var cameraPlaced = false

    init() {
        setUpEnvironment()
        setUpSky()
        setUpWater()
        setUpRipples()
        rain = makeRain()
        fireworkTemplate = Self.makeFireworkTemplate()
        scene.rootNode.addChildNode(boat.root)
        scene.rootNode.addChildNode(ghost.root)
        ghost.root.isHidden = true
        boat.onSplash = { [weak self] p, size in self?.ripple(at: p, size: size) }
        setUpNightLights()
        setUpBirds()
        setLook(.dawn, scenery: .river)
    }

    /// Clears the scenery and sets where the finish banner and grandstand go (nil for none).
    func reset(finishAt finish: Double?) {
        finishAt = Int(finish ?? 0)
        clearChunks()
        seenWild.removeAll()
        takenBottles.removeAll()
        fireworksStart = nil
        cameraPlaced = false
        clearGates()
    }

    func clearChunks() {
        for (_, c) in chunks { c.node.removeFromParentNode() }
        chunks.removeAll()
    }

    func update(dt: Double, time: Double, distance: Double, ghostDistance: Double?) {
        lastTime = time
        updateChunks(around: distance)
        boat.place(distance: distance, lane: River.laneMe, time: time)
        boat.animate(dt: dt)
        if let g = ghostDistance {
            ghost.root.isHidden = false
            ghost.place(distance: g, lane: River.laneGhost, time: time + 1)
            ghost.animate(dt: dt)
        } else {
            ghost.root.isHidden = true
        }
        updateWildlife(time: time, dt: dt, distance: distance)
        updateRipples(dt)
        updateCamera(dt)
        water.simdPosition = SIMD3((camPos.x / 50).rounded() * 50, 0, (camPos.z / 50).rounded() * 50)
        updateAtmosphere(dt: dt, time: time, distance: distance)
    }

    // MARK: - Setup

    private func setUpEnvironment() {
        scene.fogColor = Palette.fog
        scene.fogStartDistance = 45
        scene.fogEndDistance = 720
        scene.fogDensityExponent = 1

        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.1
        camera.zFar = 1500
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        // SceneKit has no hemisphere light: ambient (mostly sky, a little ground) plus a weak sky light from above.
        let ambient = ambientLight
        ambient.type = .ambient
        ambient.color = UIColor(hex: 0xc9d3d4)
        ambient.intensity = 520
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        fillLight.type = .directional
        fillLight.intensity = 130
        let fillNode = SCNNode()
        fillNode.light = fillLight
        fillNode.eulerAngles.x = -.pi / 2   // shining straight down
        scene.rootNode.addChildNode(fillNode)

        // Low sun ahead of the boat, so the water glitters.
        let sun = sunLight
        sun.type = .directional
        sun.color = UIColor(hex: 0xffe0b0)
        sun.intensity = 780
        sunNode.light = sun
        sunNode.position = SCNVector3(x: -45, y: 16, z: -88)
        sunNode.look(at: SCNVector3(x: 0, y: 0, z: 0))
        scene.rootNode.addChildNode(sunNode)
    }

    private func setUpWater() {
        let plane = SCNPlane(width: 1400, height: 1400)
        let m = waterMaterial
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(hex: 0x15302f)
        m.shaderModifiers = [.surface: Self.waterShader]
        m.setValue(Palette.linearVector(0x15302f), forKey: "deepCol")
        m.setValue(Palette.linearVector(0xb7c7ca), forKey: "skyCol")
        m.setValue(Palette.linearVector(0xffe2b0), forKey: "sunCol")
        let s = simd_normalize(SIMD3<Float>(-0.45, 0.16, -0.88))
        m.setValue(NSValue(scnVector3: SCNVector3(x: s.x, y: s.y, z: s.z)), forKey: "sunDir")
        m.setValue(NSNumber(value: 1.4), forKey: "specK")
        m.setValue(NSNumber(value: 0.0), forKey: "rainK")
        plane.materials = [m]
        water.geometry = plane
        water.eulerAngles.x = -.pi / 2
        water.renderingOrder = -1
        scene.rootNode.addChildNode(water)
    }

    /// Ripples, a Fresnel blend between deep water and sky, a sun glint, and raindrop rings, all from world position.
    private static let waterShader = """
    #pragma arguments
    float3 deepCol;
    float3 skyCol;
    float3 sunCol;
    float3 sunDir;
    float specK;
    float rainK;

    #pragma body
    #define WAVE(q) (sin((q).x*0.31+w_t*1.1)*0.5 + sin((q).y*0.23-w_t*0.8)*0.5 + sin(((q).x+(q).y)*0.92+w_t*1.7)*0.2 + sin((q).x*1.9-(q).y*1.4+w_t*2.4)*0.12 + sin((q).y*3.1+(q).x*0.7-w_t*3.0)*0.05)
    #define W_HS(q) fract(sin(dot((q), float2(12.9898, 78.233))) * 43758.5453)
    float w_t = scn_frame.time;
    float3 w_pos = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 w_cam = (scn_frame.inverseViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float2 w_p = w_pos.xz;
    float w_e = 0.2;
    float w_dx = (WAVE(w_p + float2(w_e, 0.0)) - WAVE(w_p - float2(w_e, 0.0))) / (2.0 * w_e);
    float w_dz = (WAVE(w_p + float2(0.0, w_e)) - WAVE(w_p - float2(0.0, w_e))) / (2.0 * w_e);
    float3 w_n = normalize(float3(-w_dx * 0.16, 1.0, -w_dz * 0.16));
    float3 w_v = normalize(w_cam - w_pos);
    float w_fr = pow(1.0 - max(dot(w_n, w_v), 0.0), 3.0);
    float3 w_c = mix(deepCol, skyCol, 0.12 + 0.78 * w_fr);
    float w_sp = pow(max(dot(reflect(-w_v, w_n), normalize(sunDir)), 0.0), 180.0);
    w_c += sunCol * w_sp * specK;
    if (rainK > 0.0) {
        float2 w_g = w_p / 1.3;
        float2 w_ci = floor(w_g);
        float2 w_f = fract(w_g) - 0.5;
        float w_tt = fract(w_t * 0.9 + W_HS(w_ci));
        float2 w_o = float2(W_HS(w_ci + 3.1), W_HS(w_ci + 7.7)) - 0.5;
        float w_rd = length(w_f - w_o * 0.5);
        float w_rip = (1.0 - smoothstep(0.0, 0.05, abs(w_rd - w_tt * 0.45))) * (1.0 - w_tt);
        float w_dist = length(w_cam - w_pos);
        w_c += float3(0.32) * w_rip * rainK * (1.0 - smoothstep(8.0, 55.0, w_dist));
    }
    _surface.diffuse = float4(w_c, 1.0);
    """

    private func setUpRipples() {
        let plane = SCNPlane(width: 1.44, height: 1.44)
        let m = Palette.unlit(Tex.ring(), transparent: true)
        plane.materials = [m]
        for _ in 0..<28 {
            let n = SCNNode(geometry: plane)
            n.eulerAngles.x = -.pi / 2
            n.isHidden = true
            scene.rootNode.addChildNode(n)
            ripples.append((n, 9, 1))
        }
    }

    // MARK: - Per frame

    func ripple(at p: SCNVector3, size: Double) {
        let i = rippleIndex % ripples.count
        rippleIndex += 1
        ripples[i].node.position = SCNVector3(x: p.x, y: 0.03, z: p.z)
        ripples[i].age = 0
        ripples[i].size = size
        ripples[i].node.isHidden = false
    }

    private func updateRipples(_ dt: Double) {
        let life = 3.2
        for i in ripples.indices where !ripples[i].node.isHidden {
            ripples[i].age += dt
            if ripples[i].age > life {
                ripples[i].node.isHidden = true
                continue
            }
            let s = Float((0.35 + ripples[i].age * 1.25) * ripples[i].size)
            ripples[i].node.scale = SCNVector3(x: s, y: s, z: 1)
            ripples[i].node.opacity = CGFloat(0.5 * (1 - ripples[i].age / life))
        }
    }

    private func updateCamera(_ dt: Double) {
        // Follow the river's bends smoothly rather than every wobble of the boat.
        let boatYaw = boat.root.eulerAngles.y
        if !cameraPlaced { camYaw = boatYaw }
        var dy = boatYaw - camYaw
        while dy > .pi { dy -= 2 * .pi }
        while dy < -.pi { dy += 2 * .pi }
        camYaw += dy * Float(1 - exp(-dt * 2))
        let yaw = camYaw
        let f = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))    // forward
        let r = SIMD3<Float>(cos(yaw), 0, -sin(yaw))     // right
        let b = boat.root.simdPosition
        var target: SIMD3<Float>, look: SIMD3<Float>
        switch cameraMode {
        case 1:  // alongside
            target = b - r * 10 - f * 2 + SIMD3(0, 2.4, 0)
            look = b + r * 2 + f * 3 + SIMD3(0, 0.5, 0)
        case 2:  // high
            target = b - f * 18 + r * 3 + SIMD3(0, 15, 0)
            look = b + f * 20 + r * 2
        case 3:  // looking back down the river, over the boat
            target = b + f * 12 + r * 1.5 + SIMD3(0, 4.2, 0)
            look = b - f * 40 + SIMD3(0, 3, 0)
        default: // behind
            target = b - f * 9 + r * 1.6 + SIMD3(0, 3.1, 0)
            look = b + f * 14 + r * 1.5 + SIMD3(0, 0.6, 0)
        }
        target.y = cameraMode == 2 ? 15 : target.y - b.y
        if !cameraPlaced {
            camPos = target
            camLook = look
            cameraPlaced = true
        }
        let k = Float(1 - exp(-dt * 3))
        camPos += (target - camPos) * k
        camLook += (look - camLook) * k
        cameraNode.simdPosition = camPos
        cameraNode.simdLook(at: camLook)
    }

    /// Keeps ~1.4 km of river around the boat; builds at most one new stretch per frame to avoid hitches.
    private func updateChunks(around d: Double) {
        let first = Int(floor((d - (cameraMode == 3 ? 520 : 200)) / River.chunk))
        let last = Int(floor((d + 950) / River.chunk))
        for (k, c) in chunks where k < first || k > last {
            c.node.removeFromParentNode()
            chunks[k] = nil
        }
        let current = Int(floor(d / River.chunk))
        var best: Int?
        for k in first...last where chunks[k] == nil {
            if let b = best, abs(b - current) <= abs(k - current) { continue }
            best = k
        }
        if let k = best {
            let c = buildChunk(k)
            scene.rootNode.addChildNode(c.node)
            chunks[k] = c
        }
    }

    // MARK: - Scenery

    private func buildChunk(_ k: Int) -> RiverChunk {
        let group = SCNNode()
        let chunk = RiverChunk(node: group)
        let d0 = Double(k) * River.chunk
        let W = River.width, CH = River.chunk
        let arch = scenery == .archipelago
        let lanterns = look.lanterns
        var rng = Mulberry32(seed: k * 9973 + 17)
        group.addChildNode(bank(from: d0, side: 1))
        group.addChildNode(bank(from: d0, side: -1))

        let props = SCNNode()
        let live = SCNNode()
        func put(_ g: SCNGeometry, _ x: Double, _ y: Double, _ z: Double, _ sx: Double, _ sy: Double, _ sz: Double, _ ry: Double) {
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(x: Float(x), y: Float(y), z: Float(z))
            n.scale = SCNVector3(x: Float(sx), y: Float(sy), z: Float(sz))
            n.eulerAngles.y = Float(ry)
            props.addChildNode(n)
        }

        // Spruce and birch; the archipelago keeps only half of them, and only on higher rock.
        for side in [1.0, -1.0] {
            for _ in 0..<110 {
                let o = 4 + pow(rng.next(), 1.7) * 230
                let d = d0 + rng.next() * CH
                let birch = o < 70 && rng.next() < 0.38
                let x = River.cx(d) + side * (W / 2 + o)
                let y = River.meshY(d, o, side, scenery) - 0.4
                if arch && (y < 0.7 || rng.next() < 0.5) { continue }
                let ry = rng.next() * 6
                if birch {
                    let h = 6 + rng.next() * 5
                    put(Props.birchTrunk, x, y + h * 0.36, -d, h * 0.037, h * 0.72, h * 0.037, ry)
                    put(rng.pick(Props.leaves), x, y + h * 0.68, -d, h * 0.2, h * 0.3, h * 0.2, ry)
                } else {
                    let h = 7 + rng.next() * 9
                    put(Props.trunk, x, y + h * 0.15, -d, h * 0.058, h * 0.3, h * 0.058, ry)
                    put(rng.pick(Props.spruceCones), x, y + h * 0.18 + h * 0.41, -d, h * 0.2, h * 0.82, h * 0.2, ry)
                }
            }
        }

        // Racing buoys every 10 m, white every 50 m.
        var m = Int((d0 / 10).rounded(.up)) * 10
        while Double(m) < d0 + CH {
            if m >= 0 {
                let d = Double(m)
                let g = m % 50 == 0 ? Props.buoyWhite : Props.buoyOrange
                for off in [-6.0, 0.2, 6.5] { put(g, River.cx(d) + off, 0.06, -d, 1, 1, 1, 0) }
            }
            m += 10
        }

        // Distance signs every 250 m, gates at milestones, and the finish.
        var mark = Int((d0 / 250).rounded(.up)) * 250
        while Double(mark) < d0 + CH {
            if mark > 0 { group.addChildNode(marker(at: mark)) }
            mark += 250
        }
        let finishHere = finishAt > 0 && Double(finishAt) >= d0 && Double(finishAt) < d0 + CH
        if finishHere, finishAt % 250 != 0 {
            group.addChildNode(marker(at: finishAt))
        }

        placeBottles(chunk, k: k, d0: d0, rng: &rng)
        if finishHere { SceneryBuilder.stand(at: Double(finishAt), scenery: scenery, props: props) }

        // Reeds along the water's edge.
        var reeds = ColorMesh()
        reeds.reserve(arch ? 120 : 1400)
        for side in [1.0, -1.0] {
            for _ in 0..<60 {
                if rng.next() < (arch ? 0.85 : 0.35) { continue }
                let d = d0 + rng.next() * CH, n = 3 + Int(rng.next() * 6), o = -0.9 + rng.next() * 2.2
                for _ in 0..<n {
                    let dd = d + (rng.next() - 0.5) * 2.6, oo = o + (rng.next() - 0.5) * 1.1
                    let col = ScenePart.hsl(0.11 + rng.next() * 0.06, 0.32 + rng.next() * 0.2, 0.3 + rng.next() * 0.16)
                    let h = Float(1 + rng.next() * 1.4), r = Float((rng.next() - 0.5) * 0.35)
                    reeds.reed(base: SIMD3(Float(River.cx(dd) + side * (W / 2 + oo)), -0.3, Float(-dd)), height: h, tilt: r, color: col)
                }
            }
        }

        // Stone bridges every 1.5 km on the river.
        var bm = floor(d0 / 1500) * 1500 + 700
        while bm < d0 + CH {
            if bm >= d0 && bm > 0 && !arch { SceneryBuilder.bridge(at: bm, lanterns: lanterns, props: props, live: live) }
            bm += 1500
        }

        placeWildlife(chunk, k: k, d0: d0, rng: &rng, props: props)

        // Red cottages with jetties.
        var cottages = 0
        if arch {
            cottages = rng.next() < 0.7 ? 2 : 1
        } else {
            if rng.next() < 0.55 { cottages += 1 }
            if rng.next() < 0.2 { cottages += 1 }
        }
        for _ in 0..<cottages {
            let side = rng.side(), d = d0 + 15 + rng.next() * (CH - 30), o = 9 + rng.next() * 14
            let y = River.meshY(d, o, side, scenery)
            let nearBridge = abs((d.truncatingRemainder(dividingBy: 1500) + 1500).truncatingRemainder(dividingBy: 1500) - 700) < 40
            if y < 0.35 || y > 9 || nearBridge { continue }
            SceneryBuilder.cottage(d: d, o: o, side: side, y: y, rng: &rng, lanterns: lanterns, scenery: scenery, props: props)
        }

        if arch {
            // Channel marks every 90 m, sailing boats in open water, sometimes a lighthouse on a skerry.
            var sd = (d0 / 90).rounded(.up) * 90
            while sd < d0 + CH {
                if sd > 0 {
                    let red = Int((sd / 90).rounded()) % 2 == 0
                    SceneryBuilder.spar(x: River.cx(sd) + (red ? -1 : 1) * (W / 2 - 2.2), z: -sd, red: red, props: props)
                }
                sd += 90
            }
            for _ in 0..<4 {
                let side = rng.side(), d = d0 + rng.next() * CH, o = 30 + rng.next() * 170
                if River.meshY(d, o, side, scenery) > -0.6 { continue }
                SceneryBuilder.sail(x: River.cx(d) + side * (W / 2 + o), z: -d, rng: &rng, props: props)
            }
            if rng.next() < 0.3 {
                for _ in 0..<6 {
                    let side = rng.side(), d = d0 + rng.next() * CH, o = 14 + rng.next() * 30
                    let y = River.meshY(d, o, side, scenery)
                    if y > 1.2 {
                        SceneryBuilder.lighthouse(x: River.cx(d) + side * (W / 2 + o), y: y, z: -d, lanterns: lanterns, props: props, live: live)
                        break
                    }
                }
            }
        }

        // Lanterns along the banks at night.
        if lanterns {
            var ld = (d0 / 60).rounded(.up) * 60
            while ld < d0 + CH {
                if ld > 0 {
                    for side in [1.0, -1.0] { SceneryBuilder.lantern(d: ld, side: side, scenery: scenery, props: props, live: live) }
                }
                ld += 60
            }
        }

        group.addChildNode(props.flattenedClone())
        if let r = reeds.node() { group.addChildNode(r) }
        if !live.childNodes.isEmpty { group.addChildNode(live) }
        return chunk
    }

    private func marker(at m: Int) -> SCNNode {
        let d = Double(m)
        let node = SCNNode()
        node.eulerAngles.y = River.yaw(d)
        let isFinish = finishAt > 0 && m == finishAt
        if isFinish || River.gateDistances.contains(m) {
            node.position = River.position(d, lane: 0)
            for side: Float in [-1, 1] {
                let pole = SCNNode(geometry: Props.pole)
                pole.scale = SCNVector3(x: 1, y: 7.2, z: 1)
                pole.position = SCNVector3(x: side * Float(River.width / 2 - 1.2), y: 3.6, z: 0)
                node.addChildNode(pole)
            }
            let image = isFinish
                ? Tex.sign("FINISH", size: CGSize(width: 1024, height: 96), background: UIColor(hex: 0xf4f0e6), foreground: UIColor(hex: 0x151515), chequered: true)
                : Tex.sign(Fmt.marker(m), size: CGSize(width: 1024, height: 96), background: UIColor(hex: 0xe8743a), foreground: UIColor(hex: 0xfff8ee))
            let banner = SCNPlane(width: CGFloat(River.width - 2.4), height: 2.2)
            banner.materials = [Palette.unlit(image)]
            let b = SCNNode(geometry: banner)
            b.position = SCNVector3(x: 0, y: 6.1, z: 0)
            node.addChildNode(b)
        } else {
            node.position = River.position(d, lane: -(River.width / 2 + 1.2))
            let pole = SCNNode(geometry: Props.pole)
            pole.scale = SCNVector3(x: 0.8, y: 2.6, z: 0.8)
            pole.position = SCNVector3(x: 0, y: 1.3, z: 0)
            node.addChildNode(pole)
            let sign = SCNPlane(width: 2.4, height: 0.9)
            sign.materials = [Palette.unlit(Tex.sign(Fmt.marker(m), size: CGSize(width: 256, height: 96),
                                                     background: UIColor(hex: 0xf4f0e6), foreground: UIColor(hex: 0x1d2a2c)))]
            let s = SCNNode(geometry: sign)
            s.position = SCNVector3(x: 0, y: 2.9, z: 0)
            node.addChildNode(s)
        }
        return node
    }

    /// One bank of one stretch: a height-field mesh with vertex colours.
    private func bank(from d0: Double, side: Double) -> SCNNode {
        let rows = Int(River.chunk / 5) + 1
        let cols = River.columns.count
        var positions: [SCNVector3] = []
        var colors: [Float] = []
        positions.reserveCapacity(rows * cols)
        colors.reserveCapacity(rows * cols * 3)
        for i in 0..<rows {
            let d = d0 + Double(i) * 5
            let x0 = River.cx(d)
            for o in River.columns {
                let y = River.bankY(d, o, side, scenery)
                positions.append(SCNVector3(x: Float(x0 + side * (River.width / 2 + o)), y: Float(y), z: Float(-d)))
                let c = River.bankColor(d: d, o: o, y: y, scenery: scenery)
                colors.append(contentsOf: [c.x, c.y, c.z])
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((rows - 1) * (cols - 1) * 6)
        for i in 0..<(rows - 1) {
            for j in 0..<(cols - 1) {
                let a = UInt32(i * cols + j), b = a + 1, c = a + UInt32(cols), e = c + 1
                indices.append(contentsOf: [a, c, b, b, c, e])
            }
        }
        let normals = Self.normals(positions, indices)
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: positions.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 3)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), colorSource],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [Self.bankMaterial]
        return SCNNode(geometry: geometry)
    }

    private static let bankMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.white
        m.lightingModel = .lambert
        m.locksAmbientWithDiffuse = true
        m.isDoubleSided = true
        return m
    }()

    private static func normals(_ p: [SCNVector3], _ idx: [UInt32]) -> [SCNVector3] {
        var acc = [SIMD3<Float>](repeating: .zero, count: p.count)
        func v(_ i: Int) -> SIMD3<Float> { SIMD3(p[i].x, p[i].y, p[i].z) }
        var t = 0
        while t + 2 < idx.count {
            let i0 = Int(idx[t]), i1 = Int(idx[t + 1]), i2 = Int(idx[t + 2])
            var n = simd_cross(v(i1) - v(i0), v(i2) - v(i0))
            if n.y < 0 { n = -n }
            acc[i0] += n
            acc[i1] += n
            acc[i2] += n
            t += 3
        }
        return acc.map { a in
            let n = simd_length(a) > 0 ? simd_normalize(a) : SIMD3<Float>(0, 1, 0)
            return SCNVector3(x: n.x, y: n.y, z: n.z)
        }
    }
}
