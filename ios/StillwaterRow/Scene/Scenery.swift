import SceneKit
import UIKit
import simd

/// Shared unit shapes, materials and small custom meshes for scenery and wildlife.
/// Everything static is built from these and flattened, so a stretch of river is a handful of draw calls.
@MainActor
enum ScenePart {
    enum Shape: Int { case box, sphere, cylinder, cone }

    private static var byHex: [UInt64: SCNGeometry] = [:]
    private static var byMaterial: [ObjectIdentifier: [Int: SCNGeometry]] = [:]
    private static var materials: [UInt32: SCNMaterial] = [:]

    static func material(_ hex: UInt32) -> SCNMaterial {
        if let m = materials[hex] { return m }
        let m = Palette.lambert(hex)
        materials[hex] = m
        return m
    }

    private static func make(_ shape: Shape) -> SCNGeometry {
        switch shape {
        case .box:
            return SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        case .sphere:
            let s = SCNSphere(radius: 1)
            s.segmentCount = 10
            return s
        case .cylinder:
            let c = SCNCylinder(radius: 1, height: 1)
            c.radialSegmentCount = 6
            return c
        case .cone:
            let c = SCNCone(topRadius: 0, bottomRadius: 1, height: 1)
            c.radialSegmentCount = 7
            return c
        }
    }

    static func geometry(_ shape: Shape, _ hex: UInt32) -> SCNGeometry {
        let key = UInt64(shape.rawValue) << 32 | UInt64(hex)
        if let g = byHex[key] { return g }
        let g = make(shape)
        g.materials = [material(hex)]
        byHex[key] = g
        return g
    }

    /// For materials that aren't plain lambert colours (glowing windows, glass). Keep `m` alive (a static).
    static func geometry(_ shape: Shape, _ m: SCNMaterial) -> SCNGeometry {
        let id = ObjectIdentifier(m)
        if let g = byMaterial[id]?[shape.rawValue] { return g }
        let g = make(shape)
        g.materials = [m]
        byMaterial[id, default: [:]][shape.rawValue] = g
        return g
    }

    /// Mirrors the web's `part()`: a unit shape scaled, placed and tipped about x.
    /// Cones are placed by their base (like the web's translated cone); everything else by its centre.
    static func part(_ shape: Shape, _ hex: UInt32, _ sx: Double, _ sy: Double, _ sz: Double,
                     _ x: Double, _ y: Double, _ z: Double, rx: Double = 0) -> SCNNode {
        place(geometry(shape, hex), cone: shape == .cone, sx, sy, sz, x, y, z, rx: rx)
    }

    static func part(_ shape: Shape, _ m: SCNMaterial, _ sx: Double, _ sy: Double, _ sz: Double,
                     _ x: Double, _ y: Double, _ z: Double, rx: Double = 0) -> SCNNode {
        place(geometry(shape, m), cone: shape == .cone, sx, sy, sz, x, y, z, rx: rx)
    }

    private static func place(_ g: SCNGeometry, cone: Bool, _ sx: Double, _ sy: Double, _ sz: Double,
                              _ x: Double, _ y: Double, _ z: Double, rx: Double) -> SCNNode {
        let n = SCNNode(geometry: g)
        var py = y, pz = z
        if cone {
            py += sy * 0.5 * cos(rx)
            pz += sy * 0.5 * sin(rx)
        }
        n.position = SCNVector3(x: Float(x), y: Float(py), z: Float(pz))
        n.scale = SCNVector3(x: Float(sx), y: Float(sy), z: Float(sz))
        if rx != 0 { n.eulerAngles.x = Float(rx) }
        return n
    }

    static func node(_ g: SCNGeometry, at p: SCNVector3, scale: SCNVector3? = nil) -> SCNNode {
        let n = SCNNode(geometry: g)
        n.position = p
        if let scale { n.scale = scale }
        return n
    }

    // MARK: Materials

    static let windowDay = Palette.lambert(0x2d3a44)
    static let windowNight: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(hex: 0xffcf7a)
        return m
    }()
    static let lampHead: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor(hex: 0xffe2a8)
        return m
    }()
    static let glass: SCNMaterial = {
        let m = Palette.lambert(0x3c8c5a)
        m.transparency = 0.85
        return m
    }()
    static let glowMaterial = Palette.additive(Tex.lanternGlow())
    static let streakMaterial = Palette.additive(Tex.lanternGlow(), opacity: 0.7)

    // MARK: Custom meshes

    /// A 1×1 square facing +z, drawn additively; scale it and billboard it for glows.
    static let glowPlane: SCNGeometry = {
        let p = SCNPlane(width: 1, height: 1)
        p.materials = [ScenePart.glowMaterial]
        return p
    }()

    /// A lantern's reflection on the water, lying flat.
    static let streakPlane: SCNGeometry = {
        let p = SCNPlane(width: 0.9, height: 7)
        p.materials = [ScenePart.streakMaterial]
        return p
    }()

    static let flagPlane: SCNGeometry = {
        let p = SCNPlane(width: 1.7, height: 1.06)
        let m = Palette.lambert(0xffffff)
        m.diffuse.contents = Tex.cottageFlag()
        m.isDoubleSided = true
        p.materials = [m]
        return p
    }()

    /// Stone arch under a bridge: a ring standing across the river (its lower half is under the water).
    static let arch: SCNGeometry = {
        let t = SCNTorus(ringRadius: CGFloat(River.width / 2 + 1.5), pipeRadius: 1.1)
        t.ringSegmentCount = 28
        t.pipeSegmentCount = 8
        t.materials = [ScenePart.material(0x6f6a60)]
        return t
    }()

    /// A gable roof: unit prism along x, triangle in y–z with its base at y = 0 and ridge at y = 1.
    static let roof: SCNGeometry = {
        let a0 = SCNVector3(x: -0.5, y: 0, z: -0.5), b0 = SCNVector3(x: -0.5, y: 0, z: 0.5), c0 = SCNVector3(x: -0.5, y: 1, z: 0)
        let a1 = SCNVector3(x: 0.5, y: 0, z: -0.5), b1 = SCNVector3(x: 0.5, y: 0, z: 0.5), c1 = SCNVector3(x: 0.5, y: 1, z: 0)
        let front = SCNVector3(x: 0, y: 0.4472, z: 0.8944), back = SCNVector3(x: 0, y: 0.4472, z: -0.8944)
        let left = SCNVector3(x: -1, y: 0, z: 0), right = SCNVector3(x: 1, y: 0, z: 0)
        let pos = [b0, b1, c1, b0, c1, c0,      // front slope
                   a0, c0, c1, a0, c1, a1,      // back slope
                   a0, b0, c0, a1, c1, b1]      // gable ends
        let nor = [front, front, front, front, front, front,
                   back, back, back, back, back, back,
                   left, left, left, right, right, right]
        let g = ScenePart.triangles(pos, nor)
        let m = Palette.lambert(0x34363a)
        m.isDoubleSided = true
        g.materials = [m]
        return g
    }()

    static let sailMaterial: SCNMaterial = {
        let m = Palette.lambert(0xf7f5ee)
        m.isDoubleSided = true
        return m
    }()

    static let mainsail: SCNGeometry = {
        let n = SCNVector3(x: 1, y: 0, z: 0)
        let g = ScenePart.triangles([SCNVector3(x: 0, y: 0, z: 0), SCNVector3(x: 0, y: 7, z: 0), SCNVector3(x: 0, y: 0, z: -3)], [n, n, n])
        g.materials = [ScenePart.sailMaterial]
        return g
    }()

    static let jib: SCNGeometry = {
        let n = SCNVector3(x: 1, y: 0, z: 0)
        let g = ScenePart.triangles([SCNVector3(x: 0, y: 0, z: 0), SCNVector3(x: 0, y: 6.4, z: 0), SCNVector3(x: 0, y: 0, z: 2.6)], [n, n, n])
        g.materials = [ScenePart.sailMaterial]
        return g
    }()

    static func triangles(_ positions: [SCNVector3], _ normals: [SCNVector3]) -> SCNGeometry {
        let idx = (0..<UInt32(positions.count)).map { $0 }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    /// A billboarded glow sprite of the given size.
    static func glow(_ size: Double, at p: SCNVector3) -> SCNNode {
        let n = SCNNode(geometry: glowPlane)
        n.position = p
        n.scale = SCNVector3(x: Float(size), y: Float(size), z: 1)
        n.constraints = [SCNBillboardConstraint()]
        n.renderingOrder = 6
        return n
    }

    /// HSL (0…1) to linear RGB.
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> SIMD3<Float> {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h - floor(h)) * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch Int(hp) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        func lin(_ v: Double) -> Float {
            let u = Float(clamp(v + m, 0, 1))
            return u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4)
        }
        return SIMD3(lin(r), lin(g), lin(b))
    }
}

/// Triangles with per-vertex colour, for things there are hundreds of (reeds).
struct ColorMesh {
    private var positions: [SCNVector3] = []
    private var normals: [SCNVector3] = []
    private var colors: [Float] = []

    var isEmpty: Bool { positions.isEmpty }

    mutating func reserve(_ triangles: Int) {
        positions.reserveCapacity(triangles * 3)
        normals.reserveCapacity(triangles * 3)
        colors.reserveCapacity(triangles * 9)
    }

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, outward: SIMD3<Float>, color: SIMD3<Float>) {
        var n = simd_cross(b - a, c - a)
        if simd_dot(n, outward) < 0 { n = -n }
        n = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
        let nv = SCNVector3(x: n.x, y: n.y, z: n.z)
        for p in [a, b, c] {
            positions.append(SCNVector3(x: p.x, y: p.y, z: p.z))
            normals.append(nv)
            colors.append(color.x)
            colors.append(color.y)
            colors.append(color.z)
        }
    }

    /// A three-sided reed: base in the water at `base`, tipped by the web's (r, 0, 0.7r) rotation.
    mutating func reed(base: SIMD3<Float>, height h: Float, tilt r: Float, color: SIMD3<Float>) {
        let tz = 0.7 * r
        let apex = base + h * SIMD3(-sin(tz), cos(tz) * cos(r), cos(tz) * sin(r))
        let rad: Float = 0.05
        let p0 = base + SIMD3(rad, 0, 0)
        let p1 = base + SIMD3(-rad * 0.5, 0, rad * 0.866)
        let p2 = base + SIMD3(-rad * 0.5, 0, -rad * 0.866)
        triangle(p0, p1, apex, outward: SIMD3(0.5, 0, 0.866), color: color)
        triangle(p1, p2, apex, outward: SIMD3(-1, 0, 0), color: color)
        triangle(p2, p0, apex, outward: SIMD3(0.5, 0, -0.866), color: color)
    }

    func node() -> SCNNode? {
        guard !positions.isEmpty else { return nil }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: positions.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 3)
        let idx = (0..<UInt32(positions.count)).map { $0 }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals), colorSource],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.white
        m.lightingModel = .lambert
        m.locksAmbientWithDiffuse = true
        m.isDoubleSided = true
        g.materials = [m]
        return SCNNode(geometry: g)
    }
}

/// Builders for the man-made scenery, ported from the web version's make* functions.
/// `props` is flattened afterwards; `live` keeps its nodes (billboards, things that move).
@MainActor
enum SceneryBuilder {
    static let W = River.width

    /// A stone bridge across the river at distance m.
    static func bridge(at m: Double, lanterns: Bool, props: SCNNode, live: SCNNode) {
        let g = SCNNode()
        g.position = SCNVector3(x: Float(River.cx(m)), y: 0, z: Float(-m))
        g.eulerAngles.y = River.yaw(m)
        let stone: UInt32 = 0x8d877b, stone2: UInt32 = 0x6f6a60
        g.addChildNode(ScenePart.part(.box, stone, W + 44, 1.1, 5, 0, 7.4, 0))
        for sd in [-1.0, 1.0] { g.addChildNode(ScenePart.part(.box, stone2, W + 44, 0.9, 0.35, 0, 8.4, sd * 2.3)) }
        let arch = SCNNode(geometry: ScenePart.arch)
        arch.eulerAngles.x = .pi / 2
        arch.scale = SCNVector3(x: 1, y: 2.2, z: 0.48)   // local y becomes world z (thickness), local z world y (height)
        arch.position = SCNVector3(x: 0, y: -0.4, z: 0)
        g.addChildNode(arch)
        for sd in [-1.0, 1.0] {
            g.addChildNode(ScenePart.part(.box, stone, 6, 8, 5.2, sd * (W / 2 + 4.5), 3.3, 0))
            g.addChildNode(ScenePart.part(.box, stone, 12, 9, 5, sd * (W / 2 + 14), 3.8, 0))
        }
        if lanterns {
            let lights = SCNNode()
            lights.position = g.position
            lights.eulerAngles = g.eulerAngles
            for sd in [-1.0, 1.0] {
                g.addChildNode(ScenePart.part(.cylinder, 0x3a3a36, 0.08, 1.4, 0.08, sd * (W / 2 + 3), 9.5, 2.3))
                g.addChildNode(ScenePart.part(.sphere, ScenePart.lampHead, 0.16, 0.16, 0.16, sd * (W / 2 + 3), 10.3, 2.3))
                lights.addChildNode(ScenePart.glow(2.4, at: SCNVector3(x: Float(sd * (W / 2 + 3)), y: 10.4, z: 2.3)))
            }
            live.addChildNode(lights)
        }
        props.addChildNode(g)
    }

    /// A Falu-red cottage with white corners, a jetty and usually a flag pole.
    static func cottage(d: Double, o: Double, side: Double, y: Double, rng: inout Mulberry32, lanterns: Bool,
                        scenery: Scenery, props: SCNNode) {
        let w = 4.5 + rng.next() * 2, dp = 3.6 + rng.next() * 1.2, h = 2.6 + rng.next() * 0.6
        let falu: UInt32 = 0x8e2b20, white: UInt32 = 0xf1eee6, wood: UInt32 = 0x7a6248, found: UInt32 = 0x6d6a64
        let win = lanterns ? ScenePart.windowNight : ScenePart.windowDay
        let g = SCNNode()
        g.addChildNode(ScenePart.part(.box, found, w + 0.3, 1.6, dp + 0.3, 0, -0.6, 0))
        g.addChildNode(ScenePart.part(.box, falu, w, h, dp, 0, h / 2, 0))
        for sx in [-1.0, 1.0] {
            for sz in [-1.0, 1.0] { g.addChildNode(ScenePart.part(.box, white, 0.18, h, 0.18, sx * w / 2, h / 2, sz * dp / 2)) }
        }
        let roof = SCNNode(geometry: ScenePart.roof)
        roof.scale = SCNVector3(x: Float(w + 0.5), y: 1.5, z: Float(dp + 0.7))
        roof.position = SCNVector3(x: 0, y: Float(h), z: 0)
        g.addChildNode(roof)
        for sx in [-1.0, 1.0] {
            g.addChildNode(ScenePart.part(.box, white, 1.05, 1.15, 0.06, sx * w * 0.28, h * 0.55, dp / 2 + 0.02))
            g.addChildNode(ScenePart.part(.box, win, 0.8, 0.9, 0.08, sx * w * 0.28, h * 0.55, dp / 2 + 0.04))
        }
        g.addChildNode(ScenePart.part(.box, white, 0.95, 1.9, 0.06, 0, 0.95, dp / 2 + 0.02))
        g.addChildNode(ScenePart.part(.box, wood, 0.75, 1.75, 0.08, 0, 0.88, dp / 2 + 0.04))
        g.position = SCNVector3(x: Float(River.cx(d) + side * (W / 2 + o)), y: Float(y - 0.15), z: Float(-d))
        g.eulerAngles.y = side > 0 ? -.pi / 2 : .pi / 2
        props.addChildNode(g)

        // Jetty out into the water.
        let j0 = W / 2 - 3.4, j1 = W / 2 + 2.4, jy = max(0.42, River.meshY(d, 2.4, side, scenery) + 0.12)
        props.addChildNode(ScenePart.part(.box, wood, j1 - j0, 0.14, 1.4, River.cx(d) + side * (j0 + j1) / 2, jy, -d))
        for dz in [-0.6, 0.6] {
            props.addChildNode(ScenePart.part(.cylinder, wood, 0.09, 1.6, 0.09, River.cx(d) + side * (j0 + 0.2), jy - 0.75, -d + dz))
        }
        // Flag pole by the house.
        if rng.next() < 0.7 {
            let fo = max(3, o - w / 2 - 2), fy = River.meshY(d + dp, fo, side, scenery), fx = River.cx(d + dp) + side * (W / 2 + fo)
            props.addChildNode(ScenePart.part(.cylinder, white, 0.06, 7, 0.06, fx, fy + 3.5, -(d + dp)))
            let fl = SCNNode(geometry: ScenePart.flagPlane)
            fl.position = SCNVector3(x: Float(fx - side * 0.9), y: Float(fy + 6.4), z: Float(-(d + dp)))
            fl.eulerAngles.y = side > 0 ? 0 : .pi
            props.addChildNode(fl)
        }
    }

    /// A lateral mark: red can (port) or green cone (starboard).
    static func spar(x: Double, z: Double, red: Bool, props: SCNNode) {
        let hex: UInt32 = red ? 0xc8302b : 0x2f8a4b
        let g = SCNNode()
        g.addChildNode(ScenePart.part(.cylinder, hex, 0.26, 2.6, 0.26, 0, 0.6, 0))
        if red { g.addChildNode(ScenePart.part(.cylinder, hex, 0.34, 0.5, 0.34, 0, 2.15, 0)) }
        else { g.addChildNode(ScenePart.part(.cone, hex, 0.38, 0.7, 0.38, 0, 1.9, 0)) }
        g.position = SCNVector3(x: Float(x), y: 0, z: Float(z))
        props.addChildNode(g)
    }

    /// A sailing boat lying at anchor, heeled a little.
    static func sail(x: Double, z: Double, rng: inout Mulberry32, props: SCNNode) {
        let g = SCNNode()
        let white: UInt32 = 0xf1eee6
        g.addChildNode(ScenePart.part(.sphere, white, 0.85, 0.42, 3.1, 0, 0.12, 0))
        g.addChildNode(ScenePart.part(.cylinder, white, 0.05, 8.5, 0.05, 0, 4.4, 0.3))
        g.addChildNode(ScenePart.node(ScenePart.mainsail, at: SCNVector3(x: 0, y: 0.9, z: 0.25)))
        g.addChildNode(ScenePart.node(ScenePart.jib, at: SCNVector3(x: 0, y: 0.9, z: 0.35)))
        g.position = SCNVector3(x: Float(x), y: 0, z: Float(z))
        g.eulerAngles = SCNVector3(x: 0, y: Float(rng.next() * 6.28), z: 0.12)
        props.addChildNode(g)
    }

    static func lighthouse(x: Double, y: Double, z: Double, lanterns: Bool, props: SCNNode, live: SCNNode) {
        let g = SCNNode()
        let white: UInt32 = 0xf1eee6, red: UInt32 = 0xb8322a
        g.addChildNode(ScenePart.part(.cylinder, white, 1.15, 8, 1.15, 0, 4, 0))
        g.addChildNode(ScenePart.part(.cylinder, red, 1.17, 1.6, 1.17, 0, 5.6, 0))
        g.addChildNode(ScenePart.part(.cylinder, lanterns ? 0xe8d9a8 : 0x2a2e30, 0.8, 1.2, 0.8, 0, 8.6, 0))
        g.addChildNode(ScenePart.part(.cone, red, 1, 1.3, 1, 0, 9.2, 0))
        g.position = SCNVector3(x: Float(x), y: Float(y - 0.3), z: Float(z))
        props.addChildNode(g)
        if lanterns { live.addChildNode(ScenePart.glow(7, at: SCNVector3(x: Float(x), y: Float(y - 0.3 + 8.6), z: Float(z)))) }
    }

    /// A lantern on a post at the water's edge, with its reflection on the water.
    static func lantern(d: Double, side: Double, scenery: Scenery, props: SCNNode, live: SCNNode) {
        let x = River.cx(d) + side * (W / 2 + 1.6), y = River.meshY(d, 1.6, side, scenery)
        props.addChildNode(ScenePart.part(.cylinder, 0x3a3a36, 0.06, 3, 0.06, x, y + 1.5, -d))
        props.addChildNode(ScenePart.part(.box, ScenePart.lampHead, 0.22, 0.3, 0.22, x, y + 3.1, -d))
        let st = SCNNode(geometry: ScenePart.streakPlane)
        st.eulerAngles.x = -.pi / 2
        st.position = SCNVector3(x: Float(x - side * 0.8), y: 0.03, z: Float(-d + 3.5))
        props.addChildNode(st)
        live.addChildNode(ScenePart.glow(2.2, at: SCNVector3(x: Float(x), y: Float(y + 3.1), z: Float(-d))))
    }

    private static let crowd: [UInt32] = [0xc94a3c, 0xd98a2e, 0xd6c13a, 0x5aa04a, 0x3f8fb8, 0x4b5fc4, 0x8a4fb8, 0xc24f8e]

    /// The grandstand on the right bank at the finish, full of spectators and flags.
    static func stand(at m: Double, scenery: Scenery, props: SCNNode) {
        var rng = Mulberry32(seed: Int(m) * 7 + 3)
        let g = SCNNode()
        g.position = SCNVector3(x: Float(River.cx(m) + W / 2 + 6), y: Float(River.meshY(m, 6, 1, scenery) - 0.2), z: Float(-m))
        g.eulerAngles.y = River.yaw(m) - .pi / 2
        for r in 0..<3 {
            let rh = 0.8 + Double(r) * 0.9
            g.addChildNode(ScenePart.part(.box, r % 2 == 1 ? 0x5d6a74 : 0x8a8f94, 26, rh, 2.2, 0, rh / 2, -Double(r) * 2.2))
        }
        for r in 0..<3 {
            for i in 0..<14 {
                let hex = rng.pick(crowd)
                let x = -12 + Double(i) * 1.8 + (rng.next() - 0.5) * 0.6, y = 0.8 + Double(r) * 0.9, z = -Double(r) * 2.2
                g.addChildNode(ScenePart.part(.cylinder, hex, 0.22, 0.7, 0.22, x, y + 0.35, z))
                g.addChildNode(ScenePart.part(.sphere, 0xd8a888, 0.14, 0.14, 0.14, x, y + 0.85, z))
            }
        }
        for x in [-13.0, 0, 13] {
            g.addChildNode(ScenePart.part(.cylinder, 0xf1eee6, 0.05, 3.5, 0.05, x, 4.2, -5))
            let fl = SCNNode(geometry: ScenePart.flagPlane)
            fl.position = SCNVector3(x: Float(x + 0.9), y: 5.6, z: -5)
            g.addChildNode(fl)
        }
        props.addChildNode(g)
    }

    /// A green glass bottle lying in the water, with a rolled message inside or not. Flattened; clone it.
    static let bottles: [SCNNode] = [false, true].map { (msg: Bool) -> SCNNode in
        let b = SCNNode()
        b.addChildNode(ScenePart.part(.cylinder, ScenePart.glass, 0.08, 0.32, 0.08, 0, 0, 0))
        b.addChildNode(ScenePart.part(.cylinder, ScenePart.glass, 0.035, 0.1, 0.035, 0, 0.2, 0))
        b.addChildNode(ScenePart.part(.cylinder, 0x9a7650, 0.03, 0.05, 0.03, 0, 0.27, 0))
        if msg { b.addChildNode(ScenePart.part(.cylinder, 0xf3ead2, 0.05, 0.2, 0.05, 0, 0, 0)) }
        b.eulerAngles.z = 1.25
        let g = SCNNode()
        g.addChildNode(b)
        return g.flattenedClone()
    }
}
