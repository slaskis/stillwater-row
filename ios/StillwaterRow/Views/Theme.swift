import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}

/// Glass instrument panels over the river, like a rowing monitor.
enum Theme {
    static let ink = Color(hex: 0x0b181b)
    static let mist = Color(hex: 0xe7eff0)
    static let dim = Color(hex: 0x9db3b7)
    static let amber = Color(hex: 0xf2b25c)
    static let ghost = Color(hex: 0x8fe1ee)
    static let good = Color(hex: 0x86d9a6)
    static let bad = Color(hex: 0xf29a84)
    static let line = Color.white.opacity(0.14)

    /// Condensed, tabular numerals for readouts.
    static func numbers(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed).monospacedDigit()
    }
}

struct PanelModifier: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension View {
    func panel(_ padding: CGFloat = 16) -> some View { modifier(PanelModifier(padding: padding)) }
}

/// Small uppercase label above a value.
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.3)
            .foregroundStyle(Theme.dim)
    }
}

struct Stat: View {
    let value: String
    let label: String
    var size: CGFloat = 28
    var alignment: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(value).font(Theme.numbers(size)).foregroundStyle(Theme.mist).lineLimit(1)
            Eyebrow(text: label)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(Color(hex: 0x2b1a05))
            .background(Theme.amber.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .foregroundStyle(Theme.mist)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
