import SceneKit
import UIKit
import simd

/// One built stretch of river and the things in it that move or can be spotted.
@MainActor
final class RiverChunk {
    let node: SCNNode
    var critters: [Critter] = []
    var wild: [WildSpot] = []
    var bottles: [BottleSpot] = []

    init(node: SCNNode) { self.node = node }
}

/// Something animated each frame: a bobbing seal, beaver or bottle, a paddling swan, a circling eagle.
struct Critter {
    enum Kind { case bob, swan, eagle }

    let node: SCNNode
    let kind: Kind
    let phase: Double
    var y0: Float = 0
    /// Swans: distance along the river and offset from the centre line (they paddle out of your way).
    var d: Double = 0
    var off: Double = 0
    /// Eagles: the centre of the circle they soar around.
    var centre = SIMD3<Double>(0, 0, 0)
    var wings: [(node: SCNNode, sign: Float)] = []
}

/// An animal that can be spotted, once, as the boat comes near.
struct WildSpot {
    let animal: Animal
    let d: Double
    let side: Int
    let key: Int
}

struct BottleSpot {
    let node: SCNNode
    let d: Double
    let message: Bool
    let key: Int
}

/// Low-poly animals from boxes, spheres, cylinders and cones, like the web version.
/// Static ones are flattened templates to clone; the eagle is built per instance for its wings.
@MainActor
enum Fauna {
    private static func flat(_ build: (SCNNode) -> Void) -> SCNNode {
        let g = SCNNode()
        build(g)
        return g.flattenedClone()
    }

    private static func legs(_ g: SCNNode, _ hex: UInt32, _ h: Double, _ w: Double, _ l: Double, _ r: Double) {
        for sx in [-1.0, 1.0] {
            for sz in [-1.0, 1.0] { g.addChildNode(ScenePart.part(.cylinder, hex, r, h, r, sx * w, h / 2, sz * l)) }
        }
    }

    static let white: UInt32 = 0xf1eee6, dark: UInt32 = 0x2a2e30, beak: UInt32 = 0xe07b2c

    static let swan = Fauna.flat { g in
        let c: UInt32 = 0xf6f4ee
        g.addChildNode(ScenePart.part(.sphere, c, 0.32, 0.2, 0.6, 0, 0.1, 0))
        g.addChildNode(ScenePart.part(.cylinder, c, 0.055, 0.55, 0.055, 0, 0.42, -0.42, rx: -0.25))
        g.addChildNode(ScenePart.part(.sphere, c, 0.08, 0.07, 0.12, 0, 0.68, -0.5))
        g.addChildNode(ScenePart.part(.cone, Fauna.beak, 0.03, 0.14, 0.03, 0, 0.66, -0.58, rx: -.pi / 2))
    }

    static let heron = Fauna.flat { g in
        let c: UInt32 = 0x8a9196
        g.addChildNode(ScenePart.part(.sphere, c, 0.2, 0.22, 0.42, 0, 1.02, 0, rx: 0.3))
        g.addChildNode(ScenePart.part(.cylinder, c, 0.04, 0.45, 0.04, 0, 1.36, -0.32, rx: -0.5))
        g.addChildNode(ScenePart.part(.sphere, c, 0.07, 0.06, 0.1, 0, 1.58, -0.45))
        g.addChildNode(ScenePart.part(.cone, Fauna.beak, 0.025, 0.24, 0.025, 0, 1.57, -0.5, rx: -.pi / 2))
        for sd in [-1.0, 1.0] { g.addChildNode(ScenePart.part(.cylinder, Fauna.dark, 0.018, 0.85, 0.018, sd * 0.06, 0.42, 0)) }
    }

    static let deer = Fauna.flat { g in
        let fur: UInt32 = 0x8a5a3a
        Fauna.legs(g, fur, 0.75, 0.12, 0.3, 0.035)
        g.addChildNode(ScenePart.part(.sphere, fur, 0.2, 0.24, 0.5, 0, 0.92, 0))
        g.addChildNode(ScenePart.part(.cylinder, fur, 0.06, 0.42, 0.06, 0, 1.18, -0.4, rx: -0.5))
        g.addChildNode(ScenePart.part(.sphere, fur, 0.09, 0.09, 0.17, 0, 1.38, -0.55))
        for sx in [-1.0, 1.0] { g.addChildNode(ScenePart.part(.cone, fur, 0.04, 0.14, 0.02, sx * 0.07, 1.44, -0.5)) }
        g.addChildNode(ScenePart.part(.sphere, Fauna.white, 0.08, 0.08, 0.05, 0, 0.98, 0.48))
    }

    static let fox = Fauna.flat { g in
        let f: UInt32 = 0xc8642a
        Fauna.legs(g, Fauna.dark, 0.28, 0.07, 0.18, 0.025)
        g.addChildNode(ScenePart.part(.sphere, f, 0.12, 0.13, 0.32, 0, 0.38, 0))
        g.addChildNode(ScenePart.part(.sphere, f, 0.09, 0.085, 0.12, 0, 0.47, -0.34))
        g.addChildNode(ScenePart.part(.cone, f, 0.035, 0.12, 0.035, 0, 0.45, -0.48, rx: -.pi / 2))
        for sx in [-1.0, 1.0] { g.addChildNode(ScenePart.part(.cone, f, 0.035, 0.1, 0.02, sx * 0.05, 0.55, -0.32)) }
        g.addChildNode(ScenePart.part(.sphere, f, 0.07, 0.07, 0.24, 0, 0.36, 0.44, rx: 0.5))
        g.addChildNode(ScenePart.part(.sphere, Fauna.white, 0.045, 0.045, 0.06, 0, 0.27, 0.62))
    }

    static let moose = Fauna.flat { g in
        let f: UInt32 = 0x3d2b1f
        Fauna.legs(g, f, 1.3, 0.22, 0.55, 0.07)
        g.addChildNode(ScenePart.part(.sphere, f, 0.45, 0.55, 1, 0, 1.75, 0))
        g.addChildNode(ScenePart.part(.sphere, f, 0.3, 0.3, 0.4, 0, 2.15, -0.35))
        g.addChildNode(ScenePart.part(.cylinder, f, 0.15, 0.6, 0.15, 0, 2.0, -0.9, rx: -0.9))
        g.addChildNode(ScenePart.part(.sphere, f, 0.18, 0.22, 0.42, 0, 2.05, -1.25))
        for sx in [-1.0, 1.0] {
            let a = ScenePart.part(.box, 0xc9b28a, 0.6, 0.05, 0.32, sx * 0.38, 2.42, -1.08)
            a.eulerAngles.z = Float(sx * 0.35)
            g.addChildNode(a)
        }
    }

    static let seal = Fauna.flat { g in
        let f: UInt32 = 0x6e6a66
        g.addChildNode(ScenePart.part(.sphere, f, 0.42, 0.3, 0.95, 0, 0.18, 0))
        g.addChildNode(ScenePart.part(.sphere, f, 0.22, 0.2, 0.26, 0, 0.36, -0.85))
    }

    static let beaver = Fauna.flat { g in
        let f: UInt32 = 0x5a3d28
        g.addChildNode(ScenePart.part(.sphere, f, 0.25, 0.17, 0.42, 0, 0.02, 0))
        g.addChildNode(ScenePart.part(.sphere, f, 0.13, 0.11, 0.15, 0, 0.07, -0.42))
        g.addChildNode(ScenePart.part(.box, Fauna.dark, 0.22, 0.04, 0.36, 0, 0, 0.52))
    }

    private static let eagleBody = Fauna.flat { g in
        let f: UInt32 = 0x4a3626
        g.addChildNode(ScenePart.part(.sphere, f, 0.22, 0.18, 0.6, 0, 0, 0))
        g.addChildNode(ScenePart.part(.sphere, Fauna.white, 0.13, 0.13, 0.15, 0, 0.04, -0.62))
        g.addChildNode(ScenePart.part(.box, Fauna.white, 0.35, 0.05, 0.32, 0, 0, 0.66))
    }

    /// An eagle with two wing pivots to flap.
    static func eagle() -> (node: SCNNode, wings: [(node: SCNNode, sign: Float)]) {
        let g = SCNNode()
        g.addChildNode(eagleBody.clone())
        var wings: [(node: SCNNode, sign: Float)] = []
        for sx: Float in [-1, 1] {
            let pivot = SCNNode()
            pivot.addChildNode(ScenePart.part(.box, 0x4a3626, 1.9, 0.06, 0.55, Double(sx), 0, 0))
            g.addChildNode(pivot)
            wings.append((pivot, sx))
        }
        g.scale = SCNVector3(x: 1.6, y: 1.6, z: 1.6)
        return (g, wings)
    }
}

extension RiverScene {
    /// Animals, bottles and the beaver lodge for one stretch, in the web version's order and odds.
    func placeWildlife(_ chunk: RiverChunk, k: Int, d0: Double, rng: inout Mulberry32, props: SCNNode) {
        let W = River.width, CH = River.chunk
        let arch = scenery == .archipelago
        func key(_ i: Int) -> Int { k * 16 + i }
        func add(_ animal: Animal, _ d: Double, _ side: Double) {
            let entry = WildSpot(animal: animal, d: d, side: side < 0 ? -1 : 1, key: key(chunk.wild.count))
            chunk.wild.append(entry)
        }

        // Swans, a pair on the water.
        if rng.next() < 0.55 {
            let d = d0 + 20 + rng.next() * (CH - 40), off = (rng.next() - 0.5) * 18
            for j in 0..<2 {
                let sw = Fauna.swan.clone()
                sw.eulerAngles.y = Float(rng.next() * 6)
                chunk.node.addChildNode(sw)
                var c = Critter(node: sw, kind: .swan, phase: rng.next() * 6)
                c.d = d + Double(j) * 1.6
                c.off = off + Double(j) * 0.9
                sw.position = SCNVector3(x: Float(River.cx(c.d) + c.off), y: 0, z: Float(-c.d))
                chunk.critters.append(c)
            }
            add(.swan, d, off < 0 ? -1 : 1)
        }
        // A heron standing at the water's edge.
        if rng.next() < 0.4 {
            let side = rng.side(), d = d0 + rng.next() * CH
            let hr = Fauna.heron.clone()
            hr.position = SCNVector3(x: Float(River.cx(d) + side * (W / 2 + 0.9)), y: -0.05, z: Float(-d))
            hr.eulerAngles.y = Float((side > 0 ? -1 : 1) * Double.pi / 2 + (rng.next() - 0.5))
            props.addChildNode(hr)
            add(.heron, d, side)
        }

        func spot(_ side: Double, _ omin: Double, _ omax: Double, _ ymin: Double, _ ymax: Double) -> (d: Double, o: Double, y: Double)? {
            for _ in 0..<6 {
                let d = d0 + 10 + rng.next() * (CH - 20), o = omin + rng.next() * (omax - omin)
                let y = River.meshY(d, o, side, scenery)
                if y > ymin && y < ymax { return (d, o, y) }
            }
            return nil
        }
        func face(_ side: Double) -> Double { side > 0 ? .pi / 2 : -.pi / 2 }
        func putLand(_ animal: Animal, _ template: SCNNode, _ omin: Double, _ omax: Double, _ ymin: Double) {
            let side = rng.side()
            guard let q = spot(side, omin, omax, ymin, 8) else { return }
            let m = template.clone()
            m.position = SCNVector3(x: Float(River.cx(q.d) + side * (W / 2 + q.o)), y: Float(q.y - 0.05), z: Float(-q.d))
            m.eulerAngles.y = Float(face(side) + (rng.next() - 0.5) * 0.9)
            props.addChildNode(m)
            add(animal, q.d, side)
        }

        if !arch && rng.next() < 0.12 { putLand(.deer, Fauna.deer, 5, 22, 0.3) }
        if rng.next() < 0.08 { putLand(.fox, Fauna.fox, 3, 14, 0.2) }
        if !arch && rng.next() < 0.045 { putLand(.moose, Fauna.moose, 6, 25, 0.3) }
        if rng.next() < 0.06 {
            let side = rng.side(), d = d0 + rng.next() * CH
            let e = Fauna.eagle()
            chunk.node.addChildNode(e.node)
            let centre = SIMD3<Double>(River.cx(d) + side * (W / 2 + 18), 30 + rng.next() * 10, -d)
            chunk.critters.append(Critter(node: e.node, kind: .eagle, phase: rng.next() * 6, centre: centre, wings: e.wings))
            e.node.position = SCNVector3(x: Float(centre.x), y: Float(centre.y), z: Float(centre.z))
            add(.eagle, d, side)
        }
        if arch && rng.next() < 0.18 {
            let side = rng.side()
            let sl = Fauna.seal.clone()
            if let q = spot(side, 0.5, 8, -0.1, 1.2) {
                sl.position = SCNVector3(x: Float(River.cx(q.d) + side * (W / 2 + q.o)), y: Float(q.y - 0.1), z: Float(-q.d))
                sl.eulerAngles.y = Float(face(side) + (rng.next() - 0.5))
                props.addChildNode(sl)
                add(.seal, q.d, side)
            } else {
                let d = d0 + rng.next() * CH
                sl.position = SCNVector3(x: Float(River.cx(d) + side * (W / 2 - 3)), y: -0.25, z: Float(-d))
                sl.eulerAngles.y = Float(rng.next() * 6)
                chunk.node.addChildNode(sl)
                chunk.critters.append(Critter(node: sl, kind: .bob, phase: rng.next() * 6, y0: -0.25))
                add(.seal, d, side)
            }
        }
        if !arch && rng.next() < 0.05 {
            let side = rng.side(), d = d0 + 15 + rng.next() * (CH - 30)
            let bv = Fauna.beaver.clone()
            bv.position = SCNVector3(x: Float(River.cx(d) + side * (W / 2 - 1.1)), y: 0, z: Float(-d))
            bv.eulerAngles.y = Float(rng.next() * 6)
            chunk.node.addChildNode(bv)
            chunk.critters.append(Critter(node: bv, kind: .bob, phase: rng.next() * 6, y0: 0))
            props.addChildNode(ScenePart.part(.cone, 0x5b4632, 2.4, 1.7, 2.4, River.cx(d + 4) + side * (W / 2 + 0.6), -0.5, -(d + 4)))
            add(.beaver, d, side)
        }
    }

    /// Bottles bobbing in your lane: none in 30% of stretches, then one or two.
    func placeBottles(_ chunk: RiverChunk, k: Int, d0: Double, rng: inout Mulberry32) {
        let n = rng.next() < 0.3 ? 0 : (rng.next() < 0.6 ? 1 : 2)
        for i in 0..<n {
            let d = d0 + 20 + rng.next() * (River.chunk - 40)
            if d < 60 { continue }
            let msg = rng.next() < 0.4
            let bt = SceneryBuilder.bottles[msg ? 1 : 0].clone()
            bt.position = SCNVector3(x: Float(River.cx(d) + River.laneMe + (rng.next() - 0.5) * 0.6), y: 0.04, z: Float(-d))
            bt.eulerAngles.y = Float(rng.next() * 6)
            let key = k * 16 + i
            bt.isHidden = takenBottles.contains(key)
            chunk.node.addChildNode(bt)
            chunk.bottles.append(BottleSpot(node: bt, d: d, message: msg, key: key))
            chunk.critters.append(Critter(node: bt, kind: .bob, phase: rng.next() * 6, y0: 0.04))
        }
    }

    /// Idle animation, sightings and bottle pick-ups. No allocations.
    func updateWildlife(time: Double, dt: Double, distance: Double) {
        let swim = 1 - exp(-dt * 0.72)
        for (_, chunk) in chunks {
            for i in chunk.critters.indices {
                let c = chunk.critters[i]
                switch c.kind {
                case .bob:
                    if c.node.isHidden { continue }
                    c.node.position.y = c.y0 + Float(sin(time * 1.1 + c.phase) * 0.06)
                case .eagle:
                    let a = time * 0.22 + c.phase
                    c.node.position = SCNVector3(x: Float(c.centre.x + cos(a) * 24), y: Float(c.centre.y + sin(a * 2) * 1.5),
                                                 z: Float(c.centre.z + sin(a) * 24))
                    c.node.eulerAngles = SCNVector3(x: 0, y: Float(Double.pi - a), z: -0.25)
                    let flap = Float(0.1 + sin(time * 1.6 + c.phase) * 0.12)
                    for w in c.wings { w.node.eulerAngles.z = w.sign * flap }
                case .swan:
                    var off = c.off
                    if abs(c.d - distance) < 30 && abs(off - River.laneMe) < 6 {
                        let away: Double = off - River.laneMe < 0 ? -1 : 1
                        off += (away * 11 - off) * swim
                        chunk.critters[i].off = off
                    }
                    c.node.position = SCNVector3(x: Float(River.cx(c.d) + off), y: Float(sin(time * 1.3 + c.phase) * 0.03), z: Float(-c.d))
                }
            }
            for w in chunk.wild where !seenWild.contains(w.key) {
                let a = w.d - distance
                if a < 55 && a > -10 {
                    seenWild.insert(w.key)
                    if sightingsEnabled { onSighting?(Sighting(animal: w.animal, side: w.side)) }
                }
            }
            for b in chunk.bottles where !takenBottles.contains(b.key) {
                if distance >= b.d - 2.5 && distance <= b.d + 6 {
                    takenBottles.insert(b.key)
                    b.node.isHidden = true
                    ripple(at: b.node.position, size: 0.5)
                    if sightingsEnabled { onBottle?(b.message) }
                }
            }
        }
    }
}
