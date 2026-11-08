import AVFoundation

/// The voice in your ear. Uses the best English voice installed on the device,
/// and only ducks your music while it is actually speaking.
@MainActor
final class Cox: NSObject {
    var enabled = true
    private let synth = AVSpeechSynthesizer()
    private let rivalSynth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var rivalVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        voice = Self.bestVoice()
        rivalVoice = Self.bestVoice(excluding: voice)
        synth.delegate = self
        rivalSynth.delegate = self
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

    func reloadVoice() {
        voice = Self.bestVoice()
        rivalVoice = Self.bestVoice(excluding: voice)
    }

    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        if SoundEngine.isRunning {
            // SoundEngine owns the active session. Only add ducking; keep the mode and never reactivate/deactivate.
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        } else {
            try? session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
            try? session.setActive(true)
        }
    }

    /// A regatta rival shouting across the water, in a different voice from the cox.
    func rivalSay(_ text: String) {
        guard enabled, !text.isEmpty, !rivalSynth.isSpeaking else { return }
        activateAudio()
        let u = AVSpeechUtterance(string: text)
        u.voice = rivalVoice ?? voice
        if rivalVoice == nil || rivalVoice?.identifier == voice?.identifier { u.pitchMultiplier = 1.3 }
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        rivalSynth.speak(u)
    }

    func stopAll() {
        synth.stopSpeaking(at: .immediate)
        rivalSynth.stopSpeaking(at: .immediate)
    }

    func say(_ text: String, interrupt: Bool = false) {
        guard enabled, !text.isEmpty else { return }
        if synth.isSpeaking {
            guard interrupt else { return }
            synth.stopSpeaking(at: .immediate)
        }
        activateAudio()
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        synth.speak(u)
    }

    static func pick(_ lines: [String]) -> String { lines.randomElement() ?? "" }

    static func bestVoice(excluding other: AVSpeechSynthesisVoice? = nil) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") && $0.identifier != other?.identifier }
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
        if other != nil { return voices.max { score($0) < score($1) } }
        return voices.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    private func releaseAudio() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !self.synth.isSpeaking, !self.rivalSynth.isSpeaking else { return }
            let session = AVAudioSession.sharedInstance()
            if SoundEngine.isRunning {
                // Engine still needs the session: drop ducking but stay active.
                try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
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
