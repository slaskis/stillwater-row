import SceneKit
import UIKit

/// A speed gate across the river: two posts, a floating boom and a sign. Its colour shows its state.
@MainActor
final class GateNode {
    let node = SCNNode()
    let boom: SCNMaterial
    let tops: SCNMaterial
    let gold: Bool
    var shown: SpeedGate.State = .waiting

    static let orange: UInt32 = 0xe8743a, goldHex: UInt32 = 0xf2c14e, hit: UInt32 = 0x5fd38a, miss: UInt32 = 0x7b8486

    init(gate: SpeedGate) {
        gold = gate.gold
        let base = gate.gold ? Self.goldHex : Self.orange
        boom = Palette.lambert(base)
        tops = Palette.lambert(base)
        let d = gate.d
        node.position = River.position(d, lane: 0)
        node.eulerAngles.y = River.yaw(d)
        let half = Float(River.width / 2 - 1.5)
        for side: Float in [-1, 1] {
            let post = SCNCylinder(radius: 0.16, height: 4.2)
            post.radialSegmentCount = 8
            post.materials = [Palette.lambert(0xf4f2ec)]
            let p = SCNNode(geometry: post)
            p.position = SCNVector3(x: side * half, y: 2.1, z: 0)
            node.addChildNode(p)
            let ball = SCNSphere(radius: 0.42)
            ball.segmentCount = 12
            ball.materials = [tops]
            let b = SCNNode(geometry: ball)
            b.position = SCNVector3(x: side * half, y: 4.4, z: 0)
            node.addChildNode(b)
        }
        let line = SCNBox(width: CGFloat(half * 2), height: 0.16, length: 0.3, chamferRadius: 0.06)
        line.materials = [boom]
        let l = SCNNode(geometry: line)
        l.position = SCNVector3(x: 0, y: 0.1, z: 0)
        node.addChildNode(l)
        let sign = SCNPlane(width: 7, height: 1.1)
        sign.materials = [Palette.unlit(Tex.sign(gate.gold ? "GOLD GATE" : "SPEED GATE", size: CGSize(width: 640, height: 100),
                                                 background: UIColor(hex: base), foreground: UIColor(hex: 0x1d1a14)))]
        let sn = SCNNode(geometry: sign)
        sn.position = SCNVector3(x: 0, y: 4.4, z: 0)
        node.addChildNode(sn)
    }

    func show(_ state: SpeedGate.State, time: Double) {
        switch state {
        case .live:
            let pulse = 0.55 + 0.45 * sin(time * 6)
            boom.emission.contents = UIColor(white: CGFloat(pulse * 0.6), alpha: 1)
        default:
            if state != shown {
                boom.emission.contents = UIColor.black
                let hex: UInt32
                switch state {
                case .hit: hex = Self.hit
                case .miss: hex = Self.miss
                default: hex = gold ? Self.goldHex : Self.orange
                }
                boom.diffuse.contents = UIColor(hex: hex)
                tops.diffuse.contents = UIColor(hex: hex)
            }
        }
        shown = state
    }
}

extension RiverScene {
    // MARK: Fleet

    /// Replaces the other crews on the water (empty to remove them).
    func setCrews(_ crews: [Crew]) {
        for b in crewBoats { b.root.removeFromParentNode() }
        crewBoats = crews.map { crew in
            let b = BoatNode(style: .crew(crew))
            scene.rootNode.addChildNode(b.root)
            return b
        }
    }

    func updateCrews(_ positions: [(distance: Double, lane: Double)], time: Double, dt: Double) {
        for (i, b) in crewBoats.enumerated() where i < positions.count {
            b.place(distance: positions[i].distance, lane: positions[i].lane, time: time + Double(i))
            b.animate(dt: dt)
        }
    }

    // MARK: Speed gates

    func clearGates() {
        for (_, g) in gateNodes { g.node.removeFromParentNode() }
        gateNodes.removeAll()
    }

    /// Builds gates as they come within 650 m and removes them once you're past.
    func syncGates(_ gates: [SpeedGate], distance: Double, time: Double) {
        for g in gates {
            let ahead = g.d - distance
            if let n = gateNodes[g.id] {
                if ahead < -35 {
                    n.node.removeFromParentNode()
                    gateNodes[g.id] = nil
                } else {
                    n.show(g.state, time: time)
                }
            } else if ahead < 650 && ahead > -30 {
                let n = GateNode(gate: g)
                scene.rootNode.addChildNode(n.node)
                gateNodes[g.id] = n
                n.show(g.state, time: time)
            } else if ahead >= 650 {
                break
            }
        }
    }

    // MARK: Storm

    /// Shows or hides the storm. Turning it off restores the current look exactly.
    func setStorm(_ active: Bool) {
        if active, stormWall == nil {
            let plane = SCNPlane(width: 520, height: 160)
            plane.materials = [Palette.unlit(Tex.stormWall(), transparent: true)]
            plane.firstMaterial?.isDoubleSided = true
            plane.firstMaterial?.writesToDepthBuffer = false
            let n = SCNNode(geometry: plane)
            n.renderingOrder = 5
            scene.rootNode.addChildNode(n)
            stormWall = n
        }
        stormWall?.isHidden = !active
        stormK = 0
        flashT = 0
        nextBolt = 0
        applyAtmosphere(storm: 0, flash: 0)
    }

    /// - k: 0 (clear) … 1 (the storm is on top of you), blended over the current look. `wallAt` is the squall's distance.
    func applyStorm(_ k: Double, dt: Double, time: Double, wallAt: Double?) {
        stormK += (k - stormK) * min(1, dt * 1.5)
        let s = stormK

        // Lightning once the storm is close, more often the closer it is.
        if s > 0.35, time > nextBolt {
            nextBolt = time + 3 + Double.random(in: 0..<1) * 9 * (1.4 - s)
            flashT = 0.22
            onLightning?(s)
        }
        flashT = max(0, flashT - dt)
        let fl = flashT > 0 ? sin(flashT / 0.22 * .pi) : 0
        if abs(s - appliedStorm) > 0.002 || fl > 0 || appliedFlash > 0 {
            applyAtmosphere(storm: s, flash: fl)
        }

        if let wall = stormWall, let d = wallAt {
            let sd = max(d, -200)
            let p = River.position(sd, lane: 0)
            wall.position = SCNVector3(x: p.x, y: 70, z: p.z)
            wall.eulerAngles.y = River.yaw(sd)
            wall.opacity = CGFloat(0.55 + 0.45 * s)
        }
    }
}
