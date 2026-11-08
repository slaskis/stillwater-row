import SceneKit
import UIKit
import simd

/// Shared geometry for scenery, so each stretch of river flattens into a few draw calls.
@MainActor
private enum Props {
    static let spruceCones: [SCNGeometry] = [0x1f3a24, 0x24402a, 0x2b4a2f, 0x1c3322].map { hex in
        let g = SCNCone(topRadius: 0, bottomRadius: 1, height: 1)
        g.radialSegmentCount = 7
        g.materials = [Palette.lambert(hex)]
        return g
    }
    static let leaves: [SCNGeometry] = [0xd9a032, 0xc9782a, 0xb8862e, 0xe0b84a, 0xa9552a].map { hex in
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
    var cameraMode = 0

    private let water = SCNNode()
    private var chunks: [Int: SCNNode] = [:]
    private var finishAt: Int = 0
    private var ripples: [(node: SCNNode, age: Double, size: Double)] = []
    private var rippleIndex = 0
    private var camPos = SIMD3<Float>(0, 4, 12)
    private var camLook = SIMD3<Float>(0, 0, 0)
    private var cameraPlaced = false

    init() {
        setUpEnvironment()
        setUpWater()
        setUpRipples()
        scene.rootNode.addChildNode(boat.root)
        scene.rootNode.addChildNode(ghost.root)
        ghost.root.isHidden = true
        boat.onSplash = { [weak self] p, size in self?.ripple(at: p, size: size) }
    }

    /// Clears the scenery and sets where the finish banner goes (nil for none).
    func reset(finishAt finish: Double?) {
        finishAt = Int(finish ?? 0)
        for (_, node) in chunks { node.removeFromParentNode() }
        chunks.removeAll()
        cameraPlaced = false
    }

    func update(dt: Double, time: Double, distance: Double, ghostDistance: Double?) {
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
        updateRipples(dt)
        updateCamera(dt)
        water.simdPosition = SIMD3((camPos.x / 50).rounded() * 50, 0, (camPos.z / 50).rounded() * 50)
    }

    // MARK: - Setup

    private func setUpEnvironment() {
        scene.background.contents = Tex.sky(top: Palette.skyTop, horizon: Palette.fog)
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

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(hex: 0xc9d3d4)
        ambient.intensity = 520
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Low autumn sun ahead of the boat, so the water glitters.
        let sun = SCNLight()
        sun.type = .directional
        sun.color = UIColor(hex: 0xffe0b0)
        sun.intensity = 780
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.position = SCNVector3(x: -45, y: 16, z: -88)
        sunNode.look(at: SCNVector3(x: 0, y: 0, z: 0))
        scene.rootNode.addChildNode(sunNode)
    }

    private func setUpWater() {
        let plane = SCNPlane(width: 1400, height: 1400)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(hex: 0x15302f)
        m.shaderModifiers = [.surface: Self.waterShader]
        m.setValue(Palette.linearVector(0x15302f), forKey: "deepCol")
        m.setValue(Palette.linearVector(0xb7c7ca), forKey: "skyCol")
        m.setValue(Palette.linearVector(0xffe2b0), forKey: "sunCol")
        let s = simd_normalize(SIMD3<Float>(-0.45, 0.16, -0.88))
        m.setValue(NSValue(scnVector3: SCNVector3(x: s.x, y: s.y, z: s.z)), forKey: "sunDir")
        plane.materials = [m]
        water.geometry = plane
        water.eulerAngles.x = -.pi / 2
        water.renderingOrder = -1
        scene.rootNode.addChildNode(water)
    }

    /// Ripples, a Fresnel blend between deep water and sky, and a sun glint, all from world position.
    private static let waterShader = """
    #pragma arguments
    float3 deepCol;
    float3 skyCol;
    float3 sunCol;
    float3 sunDir;

    #pragma body
    #define WAVE(q) (sin((q).x*0.31+t*1.1)*0.5 + sin((q).y*0.23-t*0.8)*0.5 + sin(((q).x+(q).y)*0.92+t*1.7)*0.2 + sin((q).x*1.9-(q).y*1.4+t*2.4)*0.12 + sin((q).y*3.1+(q).x*0.7-t*3.0)*0.05)
    float t = scn_frame.time;
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 cam = (scn_frame.inverseViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
    float2 p = wp.xz;
    float e = 0.2;
    float dx = (WAVE(p + float2(e, 0.0)) - WAVE(p - float2(e, 0.0))) / (2.0 * e);
    float dz = (WAVE(p + float2(0.0, e)) - WAVE(p - float2(0.0, e))) / (2.0 * e);
    float3 n = normalize(float3(-dx * 0.16, 1.0, -dz * 0.16));
    float3 v = normalize(cam - wp);
    float fr = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    float3 c = mix(deepCol, skyCol, 0.12 + 0.78 * fr);
    float sp = pow(max(dot(reflect(-v, n), normalize(sunDir)), 0.0), 180.0);
    c += sunCol * sp * 1.4;
    _surface.diffuse = float4(c, 1.0);
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

    private func ripple(at p: SCNVector3, size: Double) {
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
        let yaw = boat.root.eulerAngles.y
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
        let first = Int(floor((d - 200) / River.chunk))
        let last = Int(floor((d + 950) / River.chunk))
        for (k, node) in chunks where k < first || k > last {
            node.removeFromParentNode()
            chunks[k] = nil
        }
        let current = Int(floor(d / River.chunk))
        let missing = (first...last).filter { chunks[$0] == nil }.sorted { abs($0 - current) < abs($1 - current) }
        if let k = missing.first {
            let node = buildChunk(k)
            scene.rootNode.addChildNode(node)
            chunks[k] = node
        }
    }

    // MARK: - Scenery

    private func buildChunk(_ k: Int) -> SCNNode {
        let group = SCNNode()
        let d0 = Double(k) * River.chunk
        var rng = Mulberry32(seed: k * 9973 + 17)
        group.addChildNode(bank(from: d0, side: 1))
        group.addChildNode(bank(from: d0, side: -1))

        let props = SCNNode()
        func put(_ g: SCNGeometry, _ x: Double, _ y: Double, _ z: Double, _ sx: Double, _ sy: Double, _ sz: Double, _ ry: Double) {
            let n = SCNNode(geometry: g)
            n.position = SCNVector3(x: Float(x), y: Float(y), z: Float(z))
            n.scale = SCNVector3(x: Float(sx), y: Float(sy), z: Float(sz))
            n.eulerAngles.y = Float(ry)
            props.addChildNode(n)
        }

        for side in [1.0, -1.0] {
            for _ in 0..<110 {
                let o = 4 + pow(rng.next(), 1.7) * 230
                let d = d0 + rng.next() * River.chunk
                let birch = o < 70 && rng.next() < 0.38
                let x = River.cx(d) + side * (River.width / 2 + o)
                let y = River.meshY(d, o, side) - 0.4
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
        while Double(m) < d0 + River.chunk {
            if m >= 0 {
                let d = Double(m)
                let g = m % 50 == 0 ? Props.buoyWhite : Props.buoyOrange
                for off in [-6.0, 0.2, 6.5] { put(g, River.cx(d) + off, 0.06, -d, 1, 1, 1, 0) }
            }
            m += 10
        }
        group.addChildNode(props.flattenedClone())

        // Distance signs every 250 m, gates at milestones, and the finish.
        var mark = Int((d0 / 250).rounded(.up)) * 250
        while Double(mark) < d0 + River.chunk {
            if mark > 0 { group.addChildNode(marker(at: mark)) }
            mark += 250
        }
        if finishAt > 0, Double(finishAt) >= d0, Double(finishAt) < d0 + River.chunk, finishAt % 250 != 0 {
            group.addChildNode(marker(at: finishAt))
        }
        return group
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
                positions.append(SCNVector3(x: Float(x0 + side * (River.width / 2 + o)), y: Float(River.bankY(d, o, side)), z: Float(-d)))
                let c = River.bankColor(d: d, o: o)
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
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.white
        m.lightingModel = .lambert
        m.locksAmbientWithDiffuse = true
        m.isDoubleSided = true
        geometry.materials = [m]
        return SCNNode(geometry: geometry)
    }

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
