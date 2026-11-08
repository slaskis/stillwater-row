import AVFoundation

/// The voice in your ear. Uses the best English voice installed on the device,
/// and only ducks your music while it is actually speaking.
@MainActor
final class Cox: NSObject {
    var enabled = true
    private let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        voice = Self.bestVoice()
        synth.delegate = self
    }

    var voiceDescription: String {
        guard let voice else { return "System voice" }
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        default: return voice.name
        }
    }

    var hasGoodVoice: Bool { voice.map { $0.quality == .premium || $0.quality == .enhanced } ?? false }

    func reloadVoice() { voice = Self.bestVoice() }

    func say(_ text: String, interrupt: Bool = false) {
        guard enabled, !text.isEmpty else { return }
        if synth.isSpeaking {
            guard interrupt else { return }
            synth.stopSpeaking(at: .immediate)
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        synth.speak(u)
    }

    static func pick(_ lines: [String]) -> String { lines.randomElement() ?? "" }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            switch v.quality {
            case .premium: s += 6
            case .enhanced: s += 4
            default: break
            }
            if v.language == "en-GB" { s += 1 }
            if v.voiceTraits.contains(.isNoveltyVoice) { s -= 10 }
            return s
        }
        return voices.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    private func releaseAudio() {
        guard !synth.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension Cox: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseAudio() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseAudio() }
    }
}
