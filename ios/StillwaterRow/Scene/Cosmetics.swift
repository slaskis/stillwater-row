import SceneKit
import UIKit

/// Builders for the shop cosmetics: hats, pets, stern flags and wake trails.
/// Models are low-poly primitives, sized and placed like the web version (`makeHat`, `makePet`, `makeBoatFlag`).
@MainActor
enum CosmeticModels {
    private enum Shape { case sph, cyl, cone, box }

    /// Unit primitive scaled to `s`, like the web's `part()`. Cones and cylinders: x/z are the radius, y the height.
    /// Cones sit with their base at the node origin (the web translates the cone geometry up by half).
    private static func part(_ shape: Shape, _ hex: UInt32, _ s: SCNVector3, _ p: SCNVector3, rx: Float = 0, rz: Float = 0) -> SCNNode {
        let g: SCNGeometry
        switch shape {
        case .sph:
            let sphere = SCNSphere(radius: 1)
            sphere.segmentCount = 10
            g = sphere
        case .cyl:
            let c = SCNCylinder(radius: 1, height: 1)
            c.radialSegmentCount = 6
            g = c
        case .cone:
            let c = SCNCone(topRadius: 0, bottomRadius: 1, height: 1)
            c.radialSegmentCount = 7
            g = c
        case .box:
            g = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        }
        g.materials = [Palette.lambert(hex)]
        let n = SCNNode(geometry: g)
        if shape == .cone { n.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0) }
        n.scale = s
        n.position = p
        if rx != 0 || rz != 0 { n.eulerAngles = SCNVector3(x: rx, y: 0, z: rz) }
        return n
    }

    private static func v(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 { SCNVector3(x: x, y: y, z: z) }

    // MARK: Hats (children of the rower's lean node; head sits at y 0.74)

    static func hat(_ id: String) -> SCNNode? {
        let g = SCNNode()
        switch id {
        case "cap":
            g.addChildNode(part(.cyl, 0xc8302b, v(0.13, 0.07, 0.13), v(0, 0.84, 0)))
            g.addChildNode(part(.box, 0xc8302b, v(0.17, 0.015, 0.13), v(0, 0.815, 0.13)))
        case "straw":
            g.addChildNode(part(.cyl, 0xd9b56b, v(0.25, 0.02, 0.25), v(0, 0.82, 0)))
            g.addChildNode(part(.cyl, 0xd9b56b, v(0.12, 0.09, 0.12), v(0, 0.87, 0)))
            g.addChildNode(part(.cyl, 0x2c3436, v(0.123, 0.025, 0.123), v(0, 0.845, 0)))
        case "viking":
            g.addChildNode(part(.sph, 0x8d9297, v(0.135, 0.1, 0.135), v(0, 0.8, 0)))
            for sx: Float in [-1, 1] {
                g.addChildNode(part(.cone, 0xf1eee6, v(0.03, 0.17, 0.03), v(sx * 0.15, 0.85, 0), rz: -sx * 0.9))
            }
        case "crown":
            g.addChildNode(part(.cyl, 0xf2c14e, v(0.12, 0.07, 0.12), v(0, 0.86, 0)))
            for i in 0..<6 {
                let a = Float(i) / 6 * 2 * .pi
                g.addChildNode(part(.cone, 0xf2c14e, v(0.025, 0.07, 0.025), v(cos(a) * 0.11, 0.89, sin(a) * 0.11)))
            }
        default:
            return nil
        }
        return g
    }

    // MARK: Pets (children of the boat root)

    static func pet(_ id: String) -> SCNNode? {
        let g = SCNNode()
        switch id {
        case "dog":
            g.addChildNode(part(.sph, 0x8a5a3a, v(0.12, 0.11, 0.19), v(0, 0.22, 0)))
            g.addChildNode(part(.sph, 0x8a5a3a, v(0.085, 0.08, 0.09), v(0, 0.34, 0.15)))
            g.addChildNode(part(.sph, 0x3a2a20, v(0.03, 0.03, 0.03), v(0, 0.33, 0.24)))
            for sx: Float in [-1, 1] {
                g.addChildNode(part(.sph, 0x3a2a20, v(0.03, 0.06, 0.02), v(sx * 0.07, 0.36, 0.13)))
            }
            g.addChildNode(part(.cyl, 0x8a5a3a, v(0.02, 0.14, 0.02), v(0, 0.28, -0.2), rx: -0.8))
            g.position = v(0, 0, 1.7)
        case "cat":
            g.addChildNode(part(.sph, 0x7b7f85, v(0.1, 0.11, 0.16), v(0, 0.22, 0)))
            g.addChildNode(part(.sph, 0x7b7f85, v(0.075, 0.07, 0.07), v(0, 0.35, 0.11)))
            for sx: Float in [-1, 1] {
                g.addChildNode(part(.cone, 0x7b7f85, v(0.025, 0.06, 0.02), v(sx * 0.04, 0.4, 0.11)))
            }
            g.addChildNode(part(.cyl, 0x7b7f85, v(0.018, 0.26, 0.018), v(0, 0.36, -0.17), rx: -0.3))
            g.position = v(0, 0, 1.7)
        case "duck":
            g.addChildNode(part(.sph, 0xf4d03f, v(0.16, 0.13, 0.2), v(0, 0.2, 0)))
            g.addChildNode(part(.sph, 0xf4d03f, v(0.09, 0.09, 0.09), v(0, 0.36, -0.1)))
            g.addChildNode(part(.cone, 0xe8743a, v(0.03, 0.08, 0.03), v(0, 0.35, -0.2), rx: -.pi / 2))
            g.position = v(0, 0, -2.6)
        default:
            return nil
        }
        return g
    }

    // MARK: Flags (children of the boat root, at the stern)

    private static var flagImages: [String: UIImage] = [:]

    static func flagImage(_ id: String) -> UIImage {
        if let i = flagImages[id] { return i }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 60), format: f).image { ctx in
            let c = ctx.cgContext
            switch id {
            case "cheq":
                for x in 0..<8 {
                    for y in 0..<5 {
                        ((x + y) % 2 == 1 ? UIColor(hex: 0x111111) : UIColor(hex: 0xf4f4f4)).setFill()
                        c.fill(CGRect(x: x * 12, y: y * 12, width: 12, height: 12))
                    }
                }
            case "pirate":
                UIColor(hex: 0x111111).setFill()
                c.fill(CGRect(x: 0, y: 0, width: 96, height: 60))
                UIColor(hex: 0xf4f4f4).setStroke()
                c.setLineWidth(5)
                c.move(to: CGPoint(x: 30, y: 48)); c.addLine(to: CGPoint(x: 66, y: 20))
                c.move(to: CGPoint(x: 30, y: 20)); c.addLine(to: CGPoint(x: 66, y: 48))
                c.strokePath()
                UIColor(hex: 0xf4f4f4).setFill()
                c.fillEllipse(in: CGRect(x: 37, y: 16, width: 22, height: 22))
                UIColor(hex: 0x111111).setFill()
                c.fillEllipse(in: CGRect(x: 41.4, y: 23.4, width: 5.2, height: 5.2))
                c.fillEllipse(in: CGRect(x: 49.4, y: 23.4, width: 5.2, height: 5.2))
            default: // swe
                UIColor(hex: 0x006aa7).setFill()
                c.fill(CGRect(x: 0, y: 0, width: 96, height: 60))
                UIColor(hex: 0xfecc02).setFill()
                c.fill(CGRect(x: 30, y: 0, width: 12, height: 60))
                c.fill(CGRect(x: 0, y: 24, width: 96, height: 12))
            }
        }
        flagImages[id] = img
        return img
    }

    static func flag(_ id: String) -> SCNNode? {
        guard ["swe", "cheq", "pirate"].contains(id) else { return nil }
        let g = SCNNode()
        g.addChildNode(part(.cyl, 0xf1eee6, v(0.015, 0.95, 0.015), v(-0.18, 0.6, 3.7)))
        let plane = SCNPlane(width: 0.46, height: 0.29)
        let m = SCNMaterial()
        m.diffuse.contents = flagImage(id)
        m.lightingModel = .lambert
        m.locksAmbientWithDiffuse = true
        m.isDoubleSided = true
        plane.materials = [m]
        let fl = SCNNode(geometry: plane)
        fl.position = v(-0.41, 0.92, 3.7)
        fl.eulerAngles = v(0, -0.4, 0)
        g.addChildNode(fl)
        return g
    }

    // MARK: Wake trail

    private static var glowImage: UIImage = {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: f).image { ctx in
            let colors = [UIColor(white: 1, alpha: 1).cgColor, UIColor(white: 1, alpha: 0.35).cgColor,
                          UIColor(white: 1, alpha: 0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.4, 1]) {
                ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                                                 endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
            }
        }
    }()

    /// World-space particle system (particles stay where emitted). Starts with birthRate 0.
    static func trail(_ id: String) -> SCNParticleSystem? {
        guard ["sparkle", "goldwake", "rainbow"].contains(id) else { return nil }
        let ps = SCNParticleSystem()
        ps.particleImage = glowImage
        ps.isLocal = false
        ps.loops = true
        ps.birthRate = 0
        ps.emissionDuration = 1
        ps.idleDuration = 0
        ps.particleLifeSpan = 1.6
        ps.emitterShape = SCNBox(width: 0.5, height: 0.01, length: 0.01, chamferRadius: 0)
        ps.birthLocation = .volume
        ps.emittingDirection = SCNVector3(x: 0, y: 1, z: 0)
        ps.spreadingAngle = 0
        ps.particleVelocity = id == "sparkle" ? 0.25 : 0.08
        ps.particleVelocityVariation = 0
        ps.isAffectedByGravity = false
        ps.isLightingEnabled = false
        ps.blendMode = .additive
        ps.writesToDepthBuffer = false
        ps.particleSize = id == "sparkle" ? 0.37 : 0.45
        ps.particleSizeVariation = id == "sparkle" ? 0.12 : 0
        switch id {
        case "goldwake": ps.particleColor = UIColor(hex: 0xffc860)
        case "rainbow": ps.particleColor = UIColor(hue: 0, saturation: 0.75, brightness: 0.96, alpha: 1)
        default: ps.particleColor = UIColor(hex: 0xdffbff)
        }
        let fade = CAKeyframeAnimation()
        fade.values = [0.9, 0.0]
        fade.keyTimes = [0, 1]
        fade.duration = 1
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return ps
    }
}
