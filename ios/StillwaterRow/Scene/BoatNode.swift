import SceneKit
import UIKit

/// A single scull with an animated sculler: slide, body swing, and oars that dip, drive and feather.
@MainActor
final class BoatNode {
    enum Style {
        case player, ghost
        case crew(Crew)

        var isGhost: Bool { if case .ghost = self { return true } else { return false } }
    }

    let root = SCNNode()
    private let body = SCNNode()
    private let lean = SCNNode()
    private var oars: [(yaw: SCNNode, pitch: SCNNode, tip: SCNNode, side: Float)] = []
    private let labelNode = SCNNode()
    private var labelColor = UIColor(hex: 0x8fe1ee)

    private(set) var isDriving = false
    private var p: Double = 1
    private var recovery: Double = 1.6
    private var splashed = false

    private var isGhost = false
    private var hullMat: SCNMaterial?
    private var shirtMat: SCNMaterial?
    private var bladeMat: SCNMaterial?
    private var cosmetics = Cosmetics()
    private var hatNode: SCNNode?
    private var petNode: SCNNode?
    private var flagNode: SCNNode?
    private var trailHolder: SCNNode?
    private var trailSystem: SCNParticleSystem?
    private var trailID: String?

    /// Called with the blade tips' world positions when the blades enter and leave the water.
    var onSplash: ((SCNVector3, Double) -> Void)?

    /// 0…1 through the recovery; 0 while driving.
    var recoveryProgress: Double { isDriving ? 0 : p }

    func setVisible(_ visible: Bool) { root.isHidden = !visible }

    private static let catchAngle = 0.95, finishAngle = -0.55

    init(style: Style) {
        let ghost: SCNMaterial = {
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(hex: 0x8fe1ee)
            m.lightingModel = .constant
            m.transparency = 0.42
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            return m
        }()
        let isGhost = style.isGhost
        self.isGhost = isGhost
        func mat(_ hex: UInt32) -> SCNMaterial { isGhost ? ghost : Palette.lambert(hex) }
        var hullHex: UInt32 = 0xf2efe6, shirtHex: UInt32 = 0xe39a3b, bladeHex: UInt32 = 0xe8743a
        if case .crew(let c) = style {
            hullHex = c.hull
            shirtHex = c.shirt
            bladeHex = c.blade
            labelColor = c.shirt == 0x1f1f1f ? UIColor(hex: 0xe7eff0) : UIColor(hex: c.shirt).withLightness(minimum: 0.62)
        }

        func part(_ g: SCNGeometry, _ m: SCNMaterial, _ pos: SCNVector3, scale: SCNVector3? = nil, euler: SCNVector3? = nil) -> SCNNode {
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.position = pos
            if let scale { n.scale = scale }
            if let euler { n.eulerAngles = euler }
            return n
        }

        let hull = SCNSphere(radius: 1)
        hull.segmentCount = 24
        hullMat = mat(hullHex)
        shirtMat = mat(shirtHex)
        bladeMat = mat(bladeHex)
        root.addChildNode(part(hull, hullMat!, SCNVector3(x: 0, y: 0.05, z: 0), scale: SCNVector3(x: 0.25, y: 0.12, z: 4.1)))
        root.addChildNode(part(SCNBox(width: 1.72, height: 0.03, length: 0.05, chamferRadius: 0), mat(0x2c3436), SCNVector3(x: 0, y: 0.33, z: 0)))

        root.addChildNode(body)
        body.addChildNode(part(SCNBox(width: 0.3, height: 0.12, length: 0.75, chamferRadius: 0.03), mat(0x2c3436), SCNVector3(x: 0, y: 0.24, z: 0.42)))
        lean.position = SCNVector3(x: 0, y: 0.24, z: 0)
        body.addChildNode(lean)
        lean.addChildNode(part(SCNCone(topRadius: 0.15, bottomRadius: 0.2, height: 0.62), shirtMat!, SCNVector3(x: 0, y: 0.31, z: 0)))
        lean.addChildNode(part(SCNSphere(radius: 0.12), mat(0xd8a888), SCNVector3(x: 0, y: 0.74, z: 0)))

        for side: Float in [1, -1] {
            let yaw = SCNNode()
            yaw.position = SCNVector3(x: side * 0.84, y: 0.36, z: 0)
            let pitch = SCNNode()
            yaw.addChildNode(pitch)
            let shaft = SCNCylinder(radius: 0.022, height: 2.9)
            shaft.radialSegmentCount = 6
            pitch.addChildNode(part(shaft, mat(0x2b2f31), SCNVector3(x: side * 0.6, y: 0, z: 0), euler: SCNVector3(x: 0, y: 0, z: .pi / 2)))
            pitch.addChildNode(part(SCNBox(width: 0.5, height: 0.17, length: 0.025, chamferRadius: 0), bladeMat!, SCNVector3(x: side * 1.85, y: 0, z: 0)))
            let tip = SCNNode()
            tip.position = SCNVector3(x: side * 1.85, y: 0, z: 0)
            pitch.addChildNode(tip)
            root.addChildNode(yaw)
            oars.append((yaw, pitch, tip, side))
        }

        if case .player = style {} else {
            labelNode.position = SCNVector3(x: 0, y: 2.1, z: 0)
            labelNode.constraints = [SCNBillboardConstraint()]
            root.addChildNode(labelNode)
            if isGhost { root.renderingOrder = 10 }
        }
        if case .crew(let c) = style { setLabel(c.name) }
        animate(dt: 0)
    }

    /// Recolours hull, shirt and blades in place. No effect on the ghost.
    func apply(livery: Livery) {
        guard !isGhost else { return }
        hullMat?.diffuse.contents = UIColor(hex: livery.hull)
        shirtMat?.diffuse.contents = UIColor(hex: livery.shirt)
        bladeMat?.diffuse.contents = UIColor(hex: livery.blade)
    }

    /// Attaches, replaces or removes the hat, pet, stern flag and wake trail. Nil fields remove. No effect on the ghost.
    func setCosmetics(_ c: Cosmetics) {
        guard !isGhost else { return }
        if c.hat != cosmetics.hat || hatNode == nil && c.hat != nil {
            hatNode?.removeFromParentNode()
            hatNode = c.hat.flatMap { CosmeticModels.hat($0) }
            if let hatNode { lean.addChildNode(hatNode) }
        }
        if c.pet != cosmetics.pet || petNode == nil && c.pet != nil {
            petNode?.removeFromParentNode()
            petNode = c.pet.flatMap { CosmeticModels.pet($0) }
            if let petNode { root.addChildNode(petNode) }
        }
        if c.flag != cosmetics.flag || flagNode == nil && c.flag != nil {
            flagNode?.removeFromParentNode()
            flagNode = c.flag.flatMap { CosmeticModels.flag($0) }
            if let flagNode { root.addChildNode(flagNode) }
        }
        if c.trail != trailID {
            trailHolder?.removeFromParentNode()
            trailHolder = nil
            trailSystem = nil
            trailID = c.trail
            if let id = c.trail, let ps = CosmeticModels.trail(id) {
                let holder = SCNNode()
                holder.position = SCNVector3(x: 0, y: 0.15, z: 3.9)
                holder.addParticleSystem(ps)
                root.addChildNode(holder)
                trailHolder = holder
                trailSystem = ps
            }
        }
        cosmetics = c
    }

    /// Call every frame with the boat's speed (m/s). Emits wake particles only while moving.
    func updateTrail(speed: Double) {
        guard let ps = trailSystem else { return }
        ps.birthRate = speed >= 0.6 ? 22 : 0
        if trailID == "rainbow" {
            let hue = CGFloat((CACurrentMediaTime() * 0.5).truncatingRemainder(dividingBy: 1))
            ps.particleColor = UIColor(hue: hue, saturation: 0.75, brightness: 0.96, alpha: 1)
        }
    }

    func setLabel(_ text: String) {
        let plane = SCNPlane(width: 3.4 * Tex.pillWidth(text) / 512, height: 0.85)
        plane.materials = [Palette.unlit(Tex.pill(text, color: labelColor), transparent: true)]
        labelNode.geometry = plane
    }

    func stroke(recovery: Double) {
        isDriving = true
        p = 0
        self.recovery = clamp(recovery, 0.7, 2.6)
        splashed = false
    }

    func place(distance d: Double, lane: Double, time: Double) {
        root.position = River.position(d, lane: lane, y: sin(time * 1.3 + d * 0.1) * 0.02)
        root.eulerAngles.y = River.yaw(d)
    }

    func animate(dt: Double) {
        let drive = RowPhysics.driveTime
        if isDriving {
            p += dt / drive
            if !splashed && p > 0.05 {
                splashed = true
                splash(0.6)
            }
            if p >= 1 {
                isDriving = false
                p = 0
                splash(1)
            }
        } else {
            p = min(1, p + dt / recovery)
        }

        let th, slide, swing, feather: Double
        if isDriving {
            let e = easeInOut(p)
            th = lerp(Self.catchAngle, Self.finishAngle, e)
            slide = lerp(0.36, -0.26, easeInOut(min(1, p * 1.5)))
            swing = lerp(0.42, -0.32, easeInOut(clamp(p * 1.4 - 0.3, 0, 1)))
            feather = p < 0.08 ? lerp(-0.03, -0.19, p / 0.08) : (p > 0.92 ? lerp(-0.19, -0.03, (p - 0.92) / 0.08) : -0.19)
        } else {
            let e = easeInOut(p)
            th = lerp(Self.finishAngle, Self.catchAngle, e)
            swing = lerp(-0.32, 0.42, min(1, e * 1.7))
            slide = lerp(-0.26, 0.36, easeInOut(clamp(p * 1.3 - 0.3, 0, 1)))
            feather = -0.03 + sin(p * .pi) * 0.05
        }
        body.position.z = Float(slide)
        lean.eulerAngles.x = Float(swing)
        for o in oars {
            o.yaw.eulerAngles.y = o.side * Float(th)
            o.pitch.eulerAngles.z = -o.side * Float(feather)
        }
    }

    private func splash(_ size: Double) {
        guard let onSplash else { return }
        for o in oars { onSplash(o.tip.worldPosition, size) }
    }
}
