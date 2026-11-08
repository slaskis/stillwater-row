import Foundation
import simd

// MARK: - Weather and time of day

/// How the river looks: light, fog, sky and water for one time of day or weather.
struct Look: Equatable {
    var fog: UInt32
    var fogNear: Double
    var fogFar: Double
    var skyTop: UInt32
    var sun: UInt32
    var sunDirection: SIMD3<Float>
    var sunIntensity: Double      // 1 = full daylight
    var hemiSky: UInt32
    var hemiGround: UInt32
    var hemiIntensity: Double
    var deep: UInt32              // water colour looking down
    var reflection: UInt32        // water colour at grazing angles
    var specular: Double
    var sunDisc: Double           // larger = smaller, sharper sun glint
    var glow: Double              // sun glow in the sky, 0…1
    var stars = false
    var lanterns = false
    var rain = false
}

enum Condition: String, CaseIterable, Identifiable, Codable {
    case dawn, day, sunset, night, rain

    var id: String { rawValue }

    var name: String {
        switch self {
        case .dawn: return "Dawn mist"
        case .day: return "Clear day"
        case .sunset: return "Sunset"
        case .night: return "Night lanterns"
        case .rain: return "Autumn rain"
        }
    }

    /// The same presets as the web version.
    var look: Look {
        switch self {
        case .dawn:
            return Look(fog: 0xc4ced0, fogNear: 30, fogFar: 560, skyTop: 0x6e8ea4, sun: 0xffd7a0, sunDirection: SIMD3(-0.45, 0.13, -0.88),
                        sunIntensity: 0.8, hemiSky: 0xe2ebec, hemiGround: 0x3f4a30, hemiIntensity: 0.9, deep: 0x15302f, reflection: 0xb7c7ca,
                        specular: 1.4, sunDisc: 900, glow: 0.32)
        case .day:
            return Look(fog: 0xbcd0dc, fogNear: 90, fogFar: 900, skyTop: 0x4a82b6, sun: 0xfff3dc, sunDirection: SIMD3(-0.3, 0.55, -0.78),
                        sunIntensity: 1.05, hemiSky: 0xeaf2f6, hemiGround: 0x4a5534, hemiIntensity: 0.95, deep: 0x113944, reflection: 0x9fc0d6,
                        specular: 1.1, sunDisc: 1100, glow: 0.2)
        case .sunset:
            return Look(fog: 0xe0b08c, fogNear: 60, fogFar: 760, skyTop: 0x4b5a88, sun: 0xff9448, sunDirection: SIMD3(-0.18, 0.05, -0.98),
                        sunIntensity: 0.85, hemiSky: 0xf2c9a8, hemiGround: 0x3a3326, hemiIntensity: 0.75, deep: 0x2a2531, reflection: 0xe1a57c,
                        specular: 2.2, sunDisc: 320, glow: 0.75)
        case .night:
            return Look(fog: 0x121a28, fogNear: 25, fogFar: 430, skyTop: 0x04070e, sun: 0xc6d6ff, sunDirection: SIMD3(0.35, 0.32, -0.88),
                        sunIntensity: 0.3, hemiSky: 0x52628a, hemiGround: 0x0b0e12, hemiIntensity: 0.42, deep: 0x05090f, reflection: 0x1b2537,
                        specular: 1.1, sunDisc: 420, glow: 0.12, stars: true, lanterns: true)
        case .rain:
            return Look(fog: 0x8e989a, fogNear: 12, fogFar: 300, skyTop: 0x6c777b, sun: 0xd9dde0, sunDirection: SIMD3(-0.3, 0.4, -0.86),
                        sunIntensity: 0.35, hemiSky: 0xc9d1d3, hemiGround: 0x2f3529, hemiIntensity: 0.88, deep: 0x1a292a, reflection: 0x8e9a9c,
                        specular: 0.15, sunDisc: 2000, glow: 0, rain: true)
        }
    }

    /// Follows the clock: dawn in the morning, day (sometimes rain), sunset, then lanterns.
    static func auto(_ date: Date = Date(), random: Double = .random(in: 0..<1)) -> Condition {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
        if h >= 6 && h < 9.5 { return .dawn }
        if h >= 9.5 && h < 16 { return random < 0.2 ? .rain : .day }
        if h >= 16 && h < 18.5 { return .sunset }
        return .night
    }
}

/// The two landscapes the river runs through.
enum Scenery: String, CaseIterable, Identifiable, Codable {
    case river, archipelago

    var id: String { rawValue }
    var name: String { self == .river ? "Forest river" : "Archipelago" }

    static func forEvent(_ id: String) -> Scenery { ["ev6", "ev7", "ev8"].contains(id) ? .archipelago : .river }
}

// MARK: - Wildlife

enum Animal: String, CaseIterable, Identifiable, Codable {
    case swan, heron, deer, fox, seal, eagle, beaver, moose

    var id: String { rawValue }

    var name: String {
        switch self {
        case .swan: return "Mute swan"
        case .heron: return "Grey heron"
        case .deer: return "Roe deer"
        case .fox: return "Red fox"
        case .seal: return "Grey seal"
        case .eagle: return "White-tailed eagle"
        case .beaver: return "Beaver"
        case .moose: return "Moose"
        }
    }

    var rarity: String {
        switch self {
        case .swan, .heron: return "Common"
        case .deer, .fox, .seal: return "Uncommon"
        case .eagle, .beaver, .moose: return "Rare"
        }
    }

    var points: Int {
        switch self {
        case .swan, .heron: return 10
        case .deer: return 30
        case .fox, .seal: return 40
        case .eagle, .beaver: return 80
        case .moose: return 100
        }
    }

    /// Only found in one landscape, if any.
    var habitat: Scenery? {
        switch self {
        case .seal: return .archipelago
        case .beaver, .moose: return .river
        default: return nil
        }
    }
}

/// A spotted animal: which one and which bank (−1 left, +1 right).
struct Sighting: Equatable {
    let animal: Animal
    let side: Int
    var sideName: String { side < 0 ? "left" : "right" }
}

/// Messages in bottles.
enum Facts {
    static let all = [
        "Göta kanal took 22 years to build and opened in 1832.",
        "Around 58,000 soldiers helped dig Göta kanal.",
        "The Stockholm archipelago has around 30,000 islands, skerries and rocks.",
        "The first Oxford and Cambridge Boat Race was rowed in 1829.",
        "Rowers sit facing backwards, so the finish line is always behind you.",
        "Lake Vänern is the largest lake in the European Union.",
        "Rowing was on the programme at the first modern Olympics in 1896, but bad weather cancelled it.",
        "Falu red paint comes from the old copper mine in Falun.",
        "A white-tailed eagle can have a wingspan of more than two metres.",
        "Moose are strong swimmers and can cross wide lakes.",
        "Most of the power in a rowing stroke comes from the legs.",
        "Allemansrätten, the right of public access, lets everyone roam the Swedish countryside.",
    ]
}

// MARK: - Boat shop

struct Livery: Identifiable, Hashable {
    let id: String
    let name: String
    let level: Int
    let hull: UInt32
    let shirt: UInt32
    let blade: UInt32

    static let all: [Livery] = [
        Livery(id: "stillwater", name: "Stillwater", level: 1, hull: 0xf2efe6, shirt: 0xe39a3b, blade: 0xe8743a),
        Livery(id: "midnight", name: "Midnight", level: 2, hull: 0x1d2a44, shirt: 0xeef2f5, blade: 0x8fe1ee),
        Livery(id: "blueyellow", name: "Blue and yellow", level: 3, hull: 0x1f5fa8, shirt: 0xf6c843, blade: 0xf6c843),
        Livery(id: "green", name: "Racing green", level: 5, hull: 0x2f5d3a, shirt: 0xf1ead8, blade: 0xc9a227),
        Livery(id: "royal", name: "Royal", level: 8, hull: 0x4b2f6e, shirt: 0xf2d48a, blade: 0xf2d48a),
        Livery(id: "gold", name: "Gold hull", level: 12, hull: 0xd9a63c, shirt: 0x1c1c1c, blade: 0x1c1c1c),
        Livery(id: "aurora", name: "Aurora", level: 16, hull: 0x12343b, shirt: 0x5ff0c8, blade: 0xe85dbf),
    ]

    static func with(id: String) -> Livery { all.first { $0.id == id } ?? all[0] }
}

enum ShopCategory: String, CaseIterable, Identifiable, Codable {
    case hat, pet, flag, trail

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hat: return "Hats"
        case .pet: return "Crew"
        case .flag: return "Flags"
        case .trail: return "Wake"
        }
    }
}

struct ShopItem: Identifiable, Hashable {
    let id: String
    let category: ShopCategory
    let name: String
    let price: Int

    static let all: [ShopItem] = [
        ShopItem(id: "cap", category: .hat, name: "Club cap", price: 300),
        ShopItem(id: "straw", category: .hat, name: "Straw hat", price: 500),
        ShopItem(id: "viking", category: .hat, name: "Viking helmet", price: 1500),
        ShopItem(id: "crown", category: .hat, name: "Crown", price: 4000),
        ShopItem(id: "duck", category: .pet, name: "Rubber duck", price: 400),
        ShopItem(id: "dog", category: .pet, name: "Boat dog", price: 1200),
        ShopItem(id: "cat", category: .pet, name: "Ship's cat", price: 1200),
        ShopItem(id: "swe", category: .flag, name: "Swedish flag", price: 300),
        ShopItem(id: "cheq", category: .flag, name: "Chequered flag", price: 600),
        ShopItem(id: "pirate", category: .flag, name: "Pirate flag", price: 900),
        ShopItem(id: "sparkle", category: .trail, name: "Sparkle wake", price: 800),
        ShopItem(id: "goldwake", category: .trail, name: "Golden wake", price: 2000),
        ShopItem(id: "rainbow", category: .trail, name: "Rainbow wake", price: 3000),
    ]

    static func with(id: String) -> ShopItem? { all.first { $0.id == id } }
}

/// What the player's boat is wearing. Item ids from `ShopItem.all`, nil for none.
struct Cosmetics: Equatable, Codable {
    var hat: String?
    var pet: String?
    var flag: String?
    var trail: String?

    subscript(_ c: ShopCategory) -> String? {
        get {
            switch c {
            case .hat: return hat
            case .pet: return pet
            case .flag: return flag
            case .trail: return trail
            }
        }
        set {
            switch c {
            case .hat: hat = newValue
            case .pet: pet = newValue
            case .flag: flag = newValue
            case .trail: trail = newValue
            }
        }
    }
}
