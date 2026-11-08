import SceneKit
import UIKit
import simd

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// Lifts dark colours so labels stay readable on the dark pill.
    func withLightness(minimum: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: min(s, 0.75), brightness: max(b, minimum), alpha: a)
    }

    static func mix(_ x: UIColor, _ y: UIColor, _ t: Double) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        x.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        y.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let k = CGFloat(clamp(t, 0, 1))
        return UIColor(red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k, alpha: a1 + (a2 - a1) * k)
    }
}

enum Palette {
    static let fog = UIColor(hex: 0xc4ced0)
    static let skyTop = UIColor(hex: 0x6e8ea4)

    /// sRGB hex to linear RGB, for vertex colours and shader arguments, which SceneKit doesn't convert.
    static func linear(_ hex: UInt32) -> SIMD3<Float> {
        func ch(_ v: UInt32) -> Float {
            let c = Float(v & 0xff) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return SIMD3(ch(hex >> 16), ch(hex >> 8), ch(hex))
    }

    static func linearVector(_ hex: UInt32) -> NSValue {
        let c = linear(hex)
        return NSValue(scnVector3: SCNVector3(x: c.x, y: c.y, z: c.z))
    }

    static func lambert(_ hex: UInt32) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(hex: hex)
        m.lightingModel = .lambert
        m.locksAmbientWithDiffuse = true
        return m
    }

    static func unlit(_ image: UIImage, doubleSided: Bool = true, transparent: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = image
        m.lightingModel = .constant
        m.isDoubleSided = doubleSided
        if transparent {
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
        }
        return m
    }
}

/// Images drawn at runtime: signs, banners, labels, ripples and the sky.
enum Tex {
    private static func renderer(_ size: CGSize, opaque: Bool) -> UIGraphicsImageRenderer {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: f)
    }

    private static func drawCentered(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor) {
        let font = UIFont.systemFont(ofSize: size, weight: .bold, width: .condensed)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = text as NSString
        let ts = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2), withAttributes: attrs)
    }

    static func sign(_ text: String, size: CGSize, background: UIColor, foreground: UIColor, chequered: Bool = false) -> UIImage {
        renderer(size, opaque: true).image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if chequered {
                let s = size.height / 2
                UIColor(hex: 0x1b1b1b).setFill()
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    for row in 0..<2 where (col + row) % 2 == 0 {
                        ctx.fill(CGRect(x: x, y: CGFloat(row) * s, width: s, height: s))
                    }
                    x += s
                    col += 1
                }
                UIColor(white: 1, alpha: 0.92).setFill()
                ctx.fill(CGRect(x: size.width * 0.3, y: size.height * 0.12, width: size.width * 0.4, height: size.height * 0.76))
            }
            drawCentered(text, in: CGRect(origin: .zero, size: size), size: size.height * 0.6, color: foreground)
        }
    }

    /// Width of a label pill for this text, in texture pixels (height is 128).
    static func pillWidth(_ text: String) -> CGFloat { max(512, CGFloat(text.count) * 34 + 96) }

    static func pill(_ text: String, color: UIColor) -> UIImage {
        let size = CGSize(width: pillWidth(text), height: 128)
        return renderer(size, opaque: false).image { _ in
            UIColor(red: 12 / 255, green: 30 / 255, blue: 34 / 255, alpha: 0.72).setFill()
            UIBezierPath(roundedRect: CGRect(x: 4, y: 4, width: size.width - 8, height: 120), cornerRadius: 60).fill()
            drawCentered(text, in: CGRect(origin: .zero, size: size), size: 56, color: color)
        }
    }

    static func ring() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        return renderer(size, opaque: false).image { ctx in
            UIColor(white: 0.95, alpha: 1).setStroke()
            ctx.cgContext.setLineWidth(10)
            ctx.cgContext.strokeEllipse(in: CGRect(x: 14, y: 14, width: 100, height: 100))
        }
    }

    /// A dark curtain of cloud and rain, fading out at the top and bottom.
    static func stormWall() -> UIImage {
        let size = CGSize(width: 64, height: 256)
        return renderer(size, opaque: false).image { ctx in
            let c = UIColor(hex: 0x262e33)
            let colors = [c.withAlphaComponent(0).cgColor, c.withAlphaComponent(0.92).cgColor,
                          c.withAlphaComponent(0.85).cgColor, c.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 0.8, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }

    /// One raindrop streak for the rain particles.
    static func streak() -> UIImage {
        let size = CGSize(width: 8, height: 64)
        return renderer(size, opaque: false).image { ctx in
            let colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.9).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.clip(to: CGRect(x: 3, y: 0, width: 2, height: 64))
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }

    static func sky(top: UIColor, horizon: UIColor) -> UIImage {
        let size = CGSize(width: 8, height: 512)
        return renderer(size, opaque: true).image { ctx in
            let colors = [top.cgColor, horizon.cgColor, horizon.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.52, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }
}
