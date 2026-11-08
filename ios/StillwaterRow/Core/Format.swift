import Foundation

/// Display and speech formatting shared by the HUD, results, logbook and cox.
enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 0
        return f
    }()

    /// 2000 -> "2,000"
    static func meters(_ m: Double) -> String {
        let v = m.isFinite ? m.rounded() : 0
        return grouped.string(from: NSNumber(value: v)) ?? String(Int(v))
    }

    /// 125.3 -> "2:05" or, with tenths, "2:05.3"
    static func clock(_ seconds: Double, tenths: Bool = false) -> String {
        let s = seconds.isFinite ? max(0, seconds) : 0
        if tenths {
            let total = (s * 10).rounded() / 10
            let m = Int(total / 60)
            return String(format: "%d:%04.1f", m, total - Double(m) * 60)
        }
        let whole = Int(s)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Split per 500 m; a dash when the boat is (nearly) stopped.
    static func split(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 600 else { return "–:––" }
        return clock(seconds, tenths: true)
    }

    /// Distance marker text: "750 m", "1 km", "1.25 km".
    static func marker(_ m: Int) -> String {
        guard m >= 1000 else { return "\(m) m" }
        let km = Double(m) / 1000
        if km == km.rounded() { return String(format: "%.0f km", km) }
        if km * 10 == (km * 10).rounded() { return String(format: "%.1f km", km) }
        return String(format: "%.2f km", km)
    }

    /// How a cox says a split: 125 -> "2 oh 5", 120 -> "2 flat".
    static func spokenSplit(_ s: Double) -> String {
        let m = Int(s / 60)
        let r = Int((s - Double(m) * 60).rounded())
        if r >= 60 { return "\(m + 1) flat" }
        if r == 0 { return "\(m) flat" }
        return r < 10 ? "\(m) oh \(r)" : "\(m) \(r)"
    }

    static func spokenDistance(_ m: Int) -> String {
        guard m >= 1000 else { return "\(m) metres" }
        return m % 1000 == 0 ? "\(m / 1000) k" : String(format: "%.1f k", Double(m) / 1000)
    }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
