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

    /// Shows or hides the storm. Inactive scenes keep their normal weather.
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

            let ps = SCNParticleSystem()
            ps.particleImage = Tex.streak()
            ps.emitterShape = SCNBox(width: 70, height: 1, length: 70, chamferRadius: 0)
            ps.birthRate = 0
            ps.particleLifeSpan = 1.1
            ps.particleVelocity = 26
            ps.emittingDirection = SCNVector3(x: 0.08, y: -1, z: 0.05)
            ps.particleSize = 0.9
            ps.particleColor = UIColor(white: 0.85, alpha: 0.55)
            ps.blendMode = .alpha
            ps.isAffectedByGravity = false
            ps.isLightingEnabled = false
            ps.orientationMode = .billboardYAligned
            rain = ps
            let holder = SCNNode()
            holder.name = "rain"
            holder.position = SCNVector3(x: 0, y: 22, z: -12)
            holder.addParticleSystem(ps)
            cameraNode.addChildNode(holder)
        }
        stormWall?.isHidden = !active
        if !active { applyStorm(0, dt: 1, time: 0, wallAt: nil) }
    }

    /// - k: 0 (clear) … 1 (the storm is on top of you). `wallAt` is the squall's distance along the river.
    func applyStorm(_ k: Double, dt: Double, time: Double, wallAt: Double?) {
        stormK += (k - stormK) * min(1, dt * 1.5)
        let s = stormK

        // Lightning once the storm is close.
        if s > 0.55, Double.random(in: 0...1) < dt * 0.1 * s { flash = 1 }
        flash = max(0, flash - dt * 4)

        scene.fogColor = UIColor.mix(Palette.fog, UIColor(hex: 0x4a5458), s)
        scene.fogEndDistance = CGFloat(720 - 380 * s)
        ambientLight.intensity = CGFloat(520 * (1 - 0.45 * s) + 1400 * flash)
        sunLight.intensity = CGFloat(780 * (1 - 0.8 * s))
        if abs(s - skyK) > 0.04 || (s == 0 && skyK != 0) {
            skyK = s
            scene.background.contents = Tex.sky(top: UIColor.mix(Palette.skyTop, UIColor(hex: 0x2c363b), s),
                                                horizon: UIColor.mix(Palette.fog, UIColor(hex: 0x4a5458), s))
            waterMaterial.setValue(Palette.linearVector(mixHex(0xb7c7ca, 0x56626a, s)), forKey: "skyCol")
            waterMaterial.setValue(Palette.linearVector(mixHex(0x15302f, 0x101c1e, s)), forKey: "deepCol")
            waterMaterial.setValue(Palette.linearVector(mixHex(0xffe2b0, 0x30343a, s)), forKey: "sunCol")
        }
        rain?.birthRate = CGFloat(max(0, s - 0.15) * 1800)

        if let wall = stormWall, let d = wallAt {
            let sd = max(d, -200)
            let p = River.position(sd, lane: 0)
            wall.position = SCNVector3(x: p.x, y: 70, z: p.z)
            wall.eulerAngles.y = River.yaw(sd)
            wall.opacity = CGFloat(0.55 + 0.45 * s)
        }
    }

    private func mixHex(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ x: UInt32, _ shift: UInt32) -> Double { Double((x >> shift) & 0xff) }
        func m(_ shift: UInt32) -> UInt32 { UInt32(clamp((ch(a, shift) + (ch(b, shift) - ch(a, shift)) * t).rounded(), 0, 255)) << shift }
        return m(16) | m(8) | m(0)
    }
}
