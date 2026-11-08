import Foundation

/// Boat speed and distance. Two modes:
/// - tap: each stroke gives an impulse, water drag slows the boat (about 2:05/500 m at 24 strokes a minute)
/// - device: the console sets the speed while you row; when you stop, the boat glides on water drag
struct RowPhysics {
    static let driveTime = 0.72
    static let impulse = 1.2
    static let drag = 0.03

    var v: Double = 0
    var d: Double = 0
    private var driveLeft: Double = 0

    mutating func reset() {
        v = 0
        d = 0
        driveLeft = 0
    }

    mutating func tapStroke() { driveLeft = Self.driveTime }

    mutating func stepTap(dt: Double) {
        if driveLeft > 0 {
            let step = min(dt, driveLeft)
            v += Self.impulse / Self.driveTime * step
            driveLeft -= step
        }
        v = max(0, v - Self.drag * v * v * dt - (v < 0.4 ? 0.05 * dt : 0))
        d += v * dt
    }

    /// - consoleDistance: metres the console has counted this session
    /// - targetSpeed: speed reported or derived from the console (m/s)
    /// - rowing: strokes are still coming in
    /// - surge: >1 on the drive, <1 early in the recovery, for feel
    mutating func stepDevice(dt: Double, consoleDistance: Double, targetSpeed: Double, rowing: Bool, surge: Double) {
        if rowing {
            v += (targetSpeed - v) * min(1, dt * 2)
        } else {
            v = max(0, v - Self.drag * v * v * dt - 0.025 * dt)
        }
        d += v * surge * dt
        // Never fall behind the console, but glide past it when you stop.
        if consoleDistance > d { d += (consoleDistance - d) * min(1, dt) }
    }

    /// Concept2's pace-to-watts formula, used when the console gives no power.
    static func watts(speed v: Double) -> Double { 2.8 * v * v * v }
}
