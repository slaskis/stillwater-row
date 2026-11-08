import SceneKit
import UIKit

/// A single scull with an animated sculler: slide, body swing, and oars that dip, drive and feather.
@MainActor
final class BoatNode {
    enum Style { case player, ghost }

    let root = SCNNode()
    private let body = SCNNode()
    private let lean = SCNNode()
    private var oars: [(yaw: SCNNode, pitch: SCNNode, tip: SCNNode, side: Float)] = []
    private let labelNode = SCNNode()

    private(set) var isDriving = false
    private var p: Double = 1
    private var recovery: Double = 1.6
    private var splashed = false

    /// Called with the blade tips' world positions when the blades enter and leave the water.
    var onSplash: ((SCNVector3, Double) -> Void)?

    /// 0…1 through the recovery; 0 while driving.
    var recoveryProgress: Double { isDriving ? 0 : p }

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
        func mat(_ hex: UInt32) -> SCNMaterial { style == .ghost ? ghost : Palette.lambert(hex) }

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
        root.addChildNode(part(hull, mat(0xf2efe6), SCNVector3(x: 0, y: 0.05, z: 0), scale: SCNVector3(x: 0.25, y: 0.12, z: 4.1)))
        root.addChildNode(part(SCNBox(width: 1.72, height: 0.03, length: 0.05, chamferRadius: 0), mat(0x2c3436), SCNVector3(x: 0, y: 0.33, z: 0)))

        root.addChildNode(body)
        body.addChildNode(part(SCNBox(width: 0.3, height: 0.12, length: 0.75, chamferRadius: 0.03), mat(0x2c3436), SCNVector3(x: 0, y: 0.24, z: 0.42)))
        lean.position = SCNVector3(x: 0, y: 0.24, z: 0)
        body.addChildNode(lean)
        lean.addChildNode(part(SCNCone(topRadius: 0.15, bottomRadius: 0.2, height: 0.62), mat(0xe39a3b), SCNVector3(x: 0, y: 0.31, z: 0)))
        lean.addChildNode(part(SCNSphere(radius: 0.12), mat(0xd8a888), SCNVector3(x: 0, y: 0.74, z: 0)))

        for side: Float in [1, -1] {
            let yaw = SCNNode()
            yaw.position = SCNVector3(x: side * 0.84, y: 0.36, z: 0)
            let pitch = SCNNode()
            yaw.addChildNode(pitch)
            let shaft = SCNCylinder(radius: 0.022, height: 2.9)
            shaft.radialSegmentCount = 6
            pitch.addChildNode(part(shaft, mat(0x2b2f31), SCNVector3(x: side * 0.6, y: 0, z: 0), euler: SCNVector3(x: 0, y: 0, z: .pi / 2)))
            pitch.addChildNode(part(SCNBox(width: 0.5, height: 0.17, length: 0.025, chamferRadius: 0), mat(0xe8743a), SCNVector3(x: side * 1.85, y: 0, z: 0)))
            let tip = SCNNode()
            tip.position = SCNVector3(x: side * 1.85, y: 0, z: 0)
            pitch.addChildNode(tip)
            root.addChildNode(yaw)
            oars.append((yaw, pitch, tip, side))
        }

        if style == .ghost {
            labelNode.position = SCNVector3(x: 0, y: 2.1, z: 0)
            labelNode.constraints = [SCNBillboardConstraint()]
            root.addChildNode(labelNode)
            root.renderingOrder = 10
        }
        animate(dt: 0)
    }

    func setLabel(_ text: String) {
        let plane = SCNPlane(width: 3.4, height: 0.85)
        plane.materials = [Palette.unlit(Tex.pill(text, color: UIColor(hex: 0x8fe1ee)), transparent: true)]
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
