import Foundation
import SceneKit
import simd

/// The river's shape. It runs along -z; `cx(d)` is the centre line's x at distance d.
enum River {
    static let width = 26.0
    static let laneMe = -2.3
    static let laneGhost = 2.7
    static let chunk = 250.0
    static let columns: [Double] = [0, 1.5, 3, 6, 10, 16, 25, 40, 60, 90, 130, 180, 240, 330, 440]
    static let gateDistances: Set<Int> = [500, 1000, 2000, 5000, 10000]

    static func cx(_ d: Double) -> Double { 38 * sin(d / 520) + 16 * sin(d / 190 + 1.3) }
    static func dcx(_ d: Double) -> Double { 38.0 / 520 * cos(d / 520) + 16.0 / 190 * cos(d / 190 + 1.3) }
    static func yaw(_ d: Double) -> Float { Float(-atan(dcx(d))) }

    /// Bank height at distance d, offset o metres from the water's edge, on side ±1.
    static func bankY(_ d: Double, _ o: Double, _ side: Double, _ scenery: Scenery = .river) -> Double {
        switch scenery {
        case .river: return bankYRiver(d, o, side)
        case .archipelago: return bankYArch(d, o, side)
        }
    }

    static func bankYRiver(_ d: Double, _ o: Double, _ side: Double) -> Double {
        if o <= 0 { return -0.9 }
        let base = min(o, 3) * 0.24
        let rise = max(0, o - 3) * 0.03
        let hills = max(0, o - 40) / 200 * (16 + 12 * sin(d / 310 + side * 2.1) + 7 * sin(d / 97 + side * 0.7))
        return base + rise + hills
    }

    /// Where the archipelago has land (above ~0.32 near the channel, ~0.45 further out).
    static func islandMask(_ d: Double, _ o: Double, _ side: Double) -> Double {
        0.5 + 0.25 * sin(d / 173 + side * 1.7 + o / 90) + 0.18 * sin(d / 61 - o / 47 + side * 3.1) + 0.12 * sin(d / 29 + o / 23 + side)
    }

    /// Granite skerries and islands with open water between them.
    static func bankYArch(_ d: Double, _ o: Double, _ side: Double) -> Double {
        if o <= 0 { return -0.9 }
        let land = clamp((islandMask(d, o, side) - (o < 25 ? 0.32 : 0.45)) / 0.12, 0, 1)
        let rock = min(o, 4) * 0.35
            + (1.2 + 1.1 * sin(d / 37 + o / 19 + side) + 0.8 * sin(d / 13 - o / 11)) * min(1, o / 6)
            + max(0, o - 60) / 220 * 8 * (0.6 + 0.4 * sin(d / 240 + side))
        return lerp(-1.6, rock, land)
    }

    /// Height as the mesh draws it (linear between columns), for placing things on the ground.
    static func meshY(_ d: Double, _ o: Double, _ side: Double, _ scenery: Scenery = .river) -> Double {
        for j in 0..<(columns.count - 1) where o <= columns[j + 1] {
            let t = (o - columns[j]) / (columns[j + 1] - columns[j])
            return lerp(bankY(d, columns[j], side, scenery), bankY(d, columns[j + 1], side, scenery), t)
        }
        return bankY(d, o, side, scenery)
    }

    static func hash(_ a: Double, _ b: Double) -> Double {
        let s = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return s - floor(s)
    }

    private static let mud = Palette.linear(0x5b503e), grass = Palette.linear(0x8b8f4f)
    private static let moss = Palette.linear(0x4b5a37), far = Palette.linear(0x3d4d3a)
    private static let wet = Palette.linear(0x3f3a35), granite = Palette.linear(0x8b7d73), pink = Palette.linear(0x9c8077)
    private static let heath = Palette.linear(0x5f6a45), lichen = Palette.linear(0x7d8360), farArch = Palette.linear(0x46524c)

    /// River: mud at the edge, grass, moss, then distant forest floor.
    /// Archipelago: wet rock at the waterline, pink-grey granite, heath and lichen on the tops. Linear RGB.
    static func bankColor(d: Double, o: Double, y: Double = 0, scenery: Scenery = .river) -> SIMD3<Float> {
        var c: SIMD3<Float>
        switch scenery {
        case .river:
            if o < 2 { c = mud }
            else if o < 12 { c = simd_mix(mud, grass, SIMD3(repeating: Float((o - 2) / 10))) }
            else if o < 60 { c = simd_mix(grass, moss, SIMD3(repeating: Float((o - 12) / 48))) }
            else { c = simd_mix(moss, far, SIMD3(repeating: Float(min(1, (o - 60) / 220)))) }
            return c * Float(1 + (hash(d, o) - 0.5) * 0.12)
        case .archipelago:
            if y < 0.15 {
                c = wet
            } else {
                let h = hash(d * 0.37, o * 0.71 + y)
                if y > 2.2 && h > 0.45 { c = simd_mix(heath, lichen, SIMD3(repeating: Float(hash(o, d)))) }
                else { c = simd_mix(granite, pink, SIMD3(repeating: Float(h))) }
            }
            if o > 80 { c = simd_mix(c, farArch, SIMD3(repeating: Float(min(1, (o - 80) / 240)))) }
            return c * Float(1 + (hash(d, o) - 0.5) * 0.14)
        }
    }

    static func position(_ d: Double, lane: Double, y: Double = 0) -> SCNVector3 {
        SCNVector3(x: Float(cx(d) + lane), y: Float(y), z: Float(-d))
    }
}

/// Deterministic random numbers so a stretch of river always looks the same.
struct Mulberry32 {
    private var a: UInt32
    init(seed: Int) { a = UInt32(truncatingIfNeeded: seed) }

    mutating func next() -> Double {
        a = a &+ 0x6D2B_79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    mutating func pick<T>(_ items: [T]) -> T { items[min(items.count - 1, Int(next() * Double(items.count)))] }

    /// -1 or +1, evenly.
    mutating func side() -> Double { next() < 0.5 ? 1 : -1 }
}
