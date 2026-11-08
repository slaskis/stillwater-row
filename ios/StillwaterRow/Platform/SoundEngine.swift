import AVFoundation
import Foundation
import os

// Sound effects + generative music for Stillwater Row. Port of the web Web Audio code.
//
// Effects are synthesized offline into mono Float32 buffers (lazily, cached) and played
// through a small pool of AVAudioPlayerNodes. Rain and the music sequencer are synthesized
// sample-accurately inside a single AVAudioSourceNode render block (MusicSynth below).

// MARK: - Constants and DSP helpers (file private, not actor isolated)

private let kSampleRate: Double = 44100
private let monoFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: kSampleRate, channels: 1)!
private let kMaxVoices = 48

// Drum constants (web: kick 130->45 Hz over .12s, gain .45 -> .001 over .3s, stop at .32s).
private let kKickFreqN = Int(0.12 * kSampleRate)
private let kKickGainN = Int(0.30 * kSampleRate)
private let kKickEndN = Int(0.32 * kSampleRate)
private let kKickFreqMul = pow(45.0 / 130.0, 1.0 / (0.12 * kSampleRate))
private let kKickGainMul = pow(0.001 / 0.45, 1.0 / (0.30 * kSampleRate))

// Smoothing coefficients (one-pole, from setTargetAtTime time constants).
private let kMasterUpC = 1.0 - exp(-1.0 / (0.02 * kSampleRate))
private let kMasterDownC = 1.0 - exp(-1.0 / (0.30 * kSampleRate))
private let kRainC = 1.0 - exp(-1.0 / (0.50 * kSampleRate))

/// WebAudio biquad Q for lowpass/highpass is in dB.
private func qDB(_ db: Double) -> Double { pow(10.0, db / 20.0) }

private func mtof(_ n: Int) -> Double { 440.0 * pow(2.0, Double(n - 69) / 12.0) }

@inline(__always)
private func polyBLEP(_ t: Double, _ dt: Double) -> Double {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1.0
    }
    if t > 1.0 - dt {
        let x = (t - 1.0) / dt
        return x * x + x + x + 1.0
    }
    return 0.0
}

/// xorshift32 white noise in [-1, 1).
@inline(__always)
private func whiteNoise(_ s: inout UInt32) -> Double {
    s ^= s << 13
    s ^= s >> 17
    s ^= s << 5
    return Double(Int32(bitPattern: s)) / 2147483648.0
}

private struct Biquad {
    enum Kind { case lowpass, highpass, bandpass }

    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    init() {}

    /// RBJ cookbook; `q` is the linear Q (use `qDB(_:)` for WebAudio lowpass/highpass Q values).
    init(_ kind: Kind, freq: Double, q: Double) {
        let w0 = 2.0 * Double.pi * freq / kSampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2.0 * q)
        let a0 = 1.0 + alpha
        switch kind {
        case .lowpass:
            b0 = (1.0 - cosw) / 2.0 / a0
            b1 = (1.0 - cosw) / a0
            b2 = b0
        case .highpass:
            b0 = (1.0 + cosw) / 2.0 / a0
            b1 = -(1.0 + cosw) / a0
            b2 = b0
        case .bandpass:
            b0 = alpha / a0
            b1 = 0.0
            b2 = -alpha / a0
        }
        a1 = -2.0 * cosw / a0
        a2 = (1.0 - alpha) / a0
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0.0
        z2 = 0.0
    }
}

// MARK: - Music synth (audio thread)

private struct MusicParams: Sendable {
    var on = false          // sequencer running (musicWanted && musicEnabled)
    var spm = 20.0
    var level = 0           // 0...3
    var rain = 0.0          // rain gain target (0 or 0.05)
}

private struct Voice {
    var active = false
    var kind = 0            // 0 saw, 1 triangle, 2 square
    var bus = 0             // 0 pad (LP 800), 1 arp (LP 2200), 2 direct
    var phase = 0.0
    var dt = 0.0
    var env = 0.0
    var g0 = 0.0
    var attInc = 0.0
    var age = 0
    var attN = 1
    var relN = 0
    var endN = 0
    var decay = 0.0
}

private struct SynthState {
    var p = MusicParams()
    var seqRunning = false
    var step = 0
    var samplesToNext = 0.0
    var dirty = false
    var masterG = 0.0
    var rainG = 0.0
    var rng: UInt32 = 0x1234ABCD

    var padLP = Biquad(.lowpass, freq: 800, q: qDB(1))
    var arpLP = Biquad(.lowpass, freq: 2200, q: qDB(1))
    var rainHP = Biquad(.highpass, freq: 1800, q: qDB(1))

    var kickActive = false
    var kickAge = 0
    var kickPhase = 0.0
    var kickFreq = 130.0
    var kickGain = 0.0

    var snareActive = false
    var snareAge = 0
    var snareN = 0
    var snareGain = 0.0
    var snareMul = 1.0
    var snareBP = Biquad()

    var hatActive = false
    var hatAge = 0
    var hatN = 0
    var hatGain = 0.0
    var hatMul = 1.0
    var hatHP = Biquad()
}

/// All mutable DSP state lives behind raw pointers, touched only by the audio thread after init.
/// The only cross-thread channel is `params`, read with a try-lock on the audio thread.
private final class MusicSynth: @unchecked Sendable {
    let params = OSAllocatedUnfairLock(initialState: MusicParams())
    private let state: UnsafeMutablePointer<SynthState>
    private let voices: UnsafeMutablePointer<Voice>
    private let chords: UnsafeMutablePointer<Int>

    init() {
        let s = UnsafeMutablePointer<SynthState>.allocate(capacity: 1)
        s.initialize(to: SynthState())
        state = s
        let v = UnsafeMutablePointer<Voice>.allocate(capacity: kMaxVoices)
        v.initialize(repeating: Voice(), count: kMaxVoices)
        voices = v
        // Am F C G
        let notes: [Int] = [57, 60, 64, 53, 57, 60, 48, 52, 55, 55, 59, 62]
        let c = UnsafeMutablePointer<Int>.allocate(capacity: 12)
        c.initialize(from: notes, count: 12)
        chords = c
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
        voices.deinitialize(count: kMaxVoices)
        voices.deallocate()
        chords.deallocate()
    }

    // MARK: voices

    private func addVoice(kind: Int, bus: Int, freq: Double, dur: Double, g0: Double, att: Double) {
        var idx = -1
        var oldest = 0
        var oldestAge = -1
        for i in 0..<kMaxVoices {
            if !voices[i].active {
                idx = i
                break
            }
            if voices[i].age > oldestAge {
                oldestAge = voices[i].age
                oldest = i
            }
        }
        if idx < 0 { idx = oldest }
        let sr = kSampleRate
        let attN = max(1, Int(att * sr))
        let tc = dur * 0.25 + 0.05
        voices[idx] = Voice(
            active: true, kind: kind, bus: bus, phase: 0.0, dt: freq / sr,
            env: 0.0, g0: g0, attInc: g0 / Double(attN), age: 0, attN: attN,
            relN: Int(max(att, dur - 0.05) * sr), endN: Int((dur * 2.0 + 0.4) * sr),
            decay: exp(-1.0 / (tc * sr)))
    }

    private func trigger(_ st: inout SynthState, step i: Int, stepSec: Double, level L: Int) {
        st.dirty = true
        let sr = kSampleRate
        let b = i & 7
        let ci = (i >> 3) & 3
        let n0 = chords[ci * 3]
        let n1 = chords[ci * 3 + 1]
        let n2 = chords[ci * 3 + 2]

        if b == 0 {
            for k in 0..<3 {
                let f = mtof(chords[ci * 3 + k])
                addVoice(kind: 0, bus: 0, freq: f, dur: stepSec * 8.0, g0: 0.014, att: 0.4)
                addVoice(kind: 0, bus: 0, freq: f * 1.006, dur: stepSec * 8.0, g0: 0.014, att: 0.4)
            }
        }
        if L >= 1 && (b == 0 || b == 4 || b == 7) {
            addVoice(kind: 1, bus: 2, freq: mtof(n0 - 12), dur: stepSec * (b == 7 ? 1.0 : 3.0), g0: 0.13, att: 0.01)
        }
        if L >= 1 && (b == 0 || b == 4) {
            st.kickActive = true
            st.kickAge = 0
            st.kickPhase = 0.0
            st.kickFreq = 130.0
            st.kickGain = 0.45
        }
        if L >= 2 && (b == 2 || b == 6) {
            st.snareBP = Biquad(.bandpass, freq: 1500, q: 1.0)
            st.snareGain = 0.14
            st.snareMul = pow(0.0005 / 0.14, 1.0 / (0.12 * sr))
            st.snareN = Int(0.12 * sr)
            st.snareAge = 0
            st.snareActive = true
        }
        if L >= 2 {
            let g = (b & 1) == 1 ? 0.03 : 0.05
            st.hatHP = Biquad(.highpass, freq: 7000, q: qDB(1))
            st.hatGain = g
            st.hatMul = pow(0.0005 / g, 1.0 / (0.04 * sr))
            st.hatN = Int(0.04 * sr)
            st.hatAge = 0
            st.hatActive = true
        }
        if L >= 3 {
            let note: Int
            switch b {
            case 0: note = n0 + 12
            case 1: note = n1 + 12
            case 2: note = n2 + 12
            case 3: note = n0 + 24
            case 4: note = n2 + 12
            case 5: note = n1 + 12
            case 6: note = n0 + 12
            default: note = n2
            }
            addVoice(kind: 2, bus: 1, freq: mtof(note), dur: stepSec * 0.9, g0: 0.03, att: 0.005)
        }
    }

    private func clearAll(_ st: inout SynthState) {
        for i in 0..<kMaxVoices { voices[i].active = false }
        st.kickActive = false
        st.snareActive = false
        st.hatActive = false
        st.padLP.reset()
        st.arpLP.reset()
        st.dirty = false
    }

    // MARK: render (audio thread: no allocation, no blocking)

    func render(frames: Int, out: UnsafeMutablePointer<Float>) {
        var st = state.pointee
        if let np = params.withLockIfAvailable({ $0 }) { st.p = np }
        let p = st.p
        let sr = kSampleRate

        if p.on && !st.seqRunning {
            st.seqRunning = true
            st.step = 0
            st.samplesToNext = 0.12 * sr
        } else if !p.on && st.seqRunning {
            st.seqRunning = false
        }

        // Idle fast path.
        if !st.seqRunning && st.masterG < 1e-5 && st.rainG < 1e-6 && p.rain == 0.0 {
            if st.dirty { clearAll(&st) }
            for n in 0..<frames { out[n] = 0 }
            state.pointee = st
            return
        }

        let bpm = min(128.0, max(72.0, p.spm * 4.0))
        let stepSec = 60.0 / bpm / 2.0
        let level = p.level
        let masterTarget = p.on ? 0.5 : 0.0
        let rainTarget = p.rain

        for n in 0..<frames {
            // Sequencer.
            if st.seqRunning {
                st.samplesToNext -= 1.0
                if st.samplesToNext <= 0.0 {
                    trigger(&st, step: st.step, stepSec: stepSec, level: level)
                    st.samplesToNext += stepSec * sr
                    st.step = (st.step + 1) & 31
                }
            }

            // Tonal voices.
            var pad = 0.0
            var arp = 0.0
            var direct = 0.0
            var i = 0
            while i < kMaxVoices {
                let v = voices + i
                if v.pointee.active {
                    let ph = v.pointee.phase
                    let dt = v.pointee.dt
                    var o: Double
                    switch v.pointee.kind {
                    case 0:
                        o = 2.0 * ph - 1.0 - polyBLEP(ph, dt)
                    case 1:
                        o = 4.0 * abs(ph - 0.5) - 1.0
                    default:
                        var t2 = ph + 0.5
                        if t2 >= 1.0 { t2 -= 1.0 }
                        o = (ph < 0.5 ? 1.0 : -1.0) + polyBLEP(ph, dt) - polyBLEP(t2, dt)
                    }
                    var np = ph + dt
                    if np >= 1.0 { np -= 1.0 }
                    v.pointee.phase = np

                    var e = v.pointee.env
                    let age = v.pointee.age
                    if age < v.pointee.attN {
                        e += v.pointee.attInc
                    } else if age < v.pointee.relN {
                        e = v.pointee.g0
                    } else {
                        e *= v.pointee.decay
                    }
                    v.pointee.env = e
                    v.pointee.age = age + 1
                    if age + 1 >= v.pointee.endN || (age >= v.pointee.relN && e < 1e-6) {
                        v.pointee.active = false
                    }
                    o *= e
                    switch v.pointee.bus {
                    case 0: pad += o
                    case 1: arp += o
                    default: direct += o
                    }
                }
                i += 1
            }
            pad = st.padLP.process(pad)
            arp = st.arpLP.process(arp)

            // Drums.
            var drums = 0.0
            if st.kickActive {
                drums += sin(2.0 * Double.pi * st.kickPhase) * st.kickGain
                st.kickPhase += st.kickFreq / sr
                if st.kickPhase >= 1.0 { st.kickPhase -= 1.0 }
                if st.kickAge < kKickFreqN { st.kickFreq *= kKickFreqMul }
                if st.kickAge < kKickGainN { st.kickGain *= kKickGainMul }
                st.kickAge += 1
                if st.kickAge >= kKickEndN { st.kickActive = false }
            }
            if st.snareActive {
                let x = whiteNoise(&st.rng)
                drums += st.snareBP.process(x) * st.snareGain
                st.snareGain *= st.snareMul
                st.snareAge += 1
                if st.snareAge >= st.snareN { st.snareActive = false }
            }
            if st.hatActive {
                let x = whiteNoise(&st.rng)
                drums += st.hatHP.process(x) * st.hatGain
                st.hatGain *= st.hatMul
                st.hatAge += 1
                if st.hatAge >= st.hatN { st.hatActive = false }
            }

            // Music master (fast attack, 0.3 s release like the web's setTargetAtTime).
            st.masterG += (masterTarget - st.masterG) * (masterTarget > st.masterG ? kMasterUpC : kMasterDownC)
            let music = (pad + arp + direct + drums) * st.masterG

            // Rain bed.
            var rain = 0.0
            if st.rainG > 1e-6 || rainTarget > 0.0 {
                rain = st.rainHP.process(whiteNoise(&st.rng)) * st.rainG
                st.rainG += (rainTarget - st.rainG) * kRainC
            }

            let mixed = music + rain
            out[n] = Float(max(-1.0, min(1.0, mixed)))
        }
        state.pointee = st
    }
}

// MARK: - Effect rendering (offline, main thread, pure functions)

private enum FxKey: Hashable {
    case splash(Int)
    case thunder(Int)
    case plink, pop, horn, tick, dingGold, dingPlain, thud, applause, chime
}

private func renderFx(_ key: FxKey) -> [Float] {
    switch key {
    case .splash(let i): return fxSplash(freq: 700.0 + Double(i) * 100.0)
    case .thunder(let i): return fxThunder(rate: [0.75, 0.92, 1.1][i % 3])
    case .plink:
        return fxSweep(triangle: false, f0: 1300, f1: 2100, fRamp: 0.08, g0: 0.12, g1: 0.001, gRamp: 0.25, length: 0.27)
    case .pop:
        return fxSweep(triangle: true, f0: 320, f1: 70, fRamp: 0.35, g0: 0.2, g1: 0.001, gRamp: 0.4, length: 0.42)
    case .thud:
        return fxSweep(triangle: false, f0: 220, f1: 90, fRamp: 0.25, g0: 0.16, g1: 0.001, gRamp: 0.3, length: 0.32)
    case .horn: return fxHorn()
    case .tick:
        var out = [Float](repeating: 0, count: Int(0.08 * kSampleRate))
        fxAddPartial(&out, triangle: true, start: 0, freq: 1250, peak: 0.09, attack: 0.005, floor: 0.0001, decayEnd: 0.07, stop: 0.08)
        return out
    case .dingGold: return fxDing(freqs: [880, 1175, 1568])
    case .dingPlain: return fxDing(freqs: [1046, 1568])
    case .chime:
        var out = [Float](repeating: 0, count: Int(1.12 * kSampleRate))
        for (i, fq) in [660.0, 990.0].enumerated() {
            fxAddPartial(&out, triangle: false, start: Double(i) * 0.12, freq: fq, peak: 0.12, attack: 0.02, floor: 0.001, decayEnd: 0.9, stop: 1.0)
        }
        return out
    case .applause: return fxApplause()
    }
}

private func fxSweep(triangle: Bool, f0: Double, f1: Double, fRamp: Double,
                     g0: Double, g1: Double, gRamp: Double, length: Double) -> [Float] {
    let n = Int(length * kSampleRate)
    var out = [Float](repeating: 0, count: n)
    var ph = 0.0
    for i in 0..<n {
        let t = Double(i) / kSampleRate
        let f = f0 * pow(f1 / f0, min(t, fRamp) / fRamp)
        let g = g0 * pow(g1 / g0, min(t, gRamp) / gRamp)
        ph += f / kSampleRate
        if ph >= 1.0 { ph -= 1.0 }
        let o = triangle ? (4.0 * abs(ph - 0.5) - 1.0) : sin(2.0 * Double.pi * ph)
        out[i] = Float(o * g)
    }
    return out
}

/// Linear attack to `peak`, then exponential decay to `floor` at `decayEnd`, silent after `stop` (all relative to `start`).
private func fxAddPartial(_ out: inout [Float], triangle: Bool, start: Double, freq: Double,
                          peak: Double, attack: Double, floor: Double, decayEnd: Double, stop: Double) {
    let s0 = Int(start * kSampleRate)
    let n = Int(stop * kSampleRate)
    let dph = freq / kSampleRate
    var ph = 0.0
    for i in 0..<n {
        let idx = s0 + i
        if idx >= out.count { break }
        let t = Double(i) / kSampleRate
        let g: Double
        if t < attack {
            g = peak * t / attack
        } else {
            g = peak * pow(floor / peak, min(1.0, (t - attack) / (decayEnd - attack)))
        }
        let o = triangle ? (4.0 * abs(ph - 0.5) - 1.0) : sin(2.0 * Double.pi * ph)
        ph += dph
        if ph >= 1.0 { ph -= 1.0 }
        out[idx] += Float(o * g)
    }
}

private func fxDing(freqs: [Double]) -> [Float] {
    let total = Double(freqs.count - 1) * 0.07 + 0.55
    var out = [Float](repeating: 0, count: Int(total * kSampleRate))
    for (i, fq) in freqs.enumerated() {
        fxAddPartial(&out, triangle: false, start: Double(i) * 0.07, freq: fq, peak: 0.11, attack: 0.01, floor: 0.001, decayEnd: 0.5, stop: 0.55)
    }
    return out
}

private func fxHorn() -> [Float] {
    let n = Int(1.0 * kSampleRate)
    var mix = [Double](repeating: 0, count: n)
    for fq in [220.0, 277.0, 330.0] {
        var ph = 0.0
        let dt = fq / kSampleRate
        for i in 0..<n {
            let t = Double(i) / kSampleRate
            var env = 0.07
            if t < 0.03 {
                env = 0.07 * t / 0.03
            } else if t > 0.75 {
                env = max(0.0, 0.07 * (1.0 - (t - 0.75) / 0.2))
            }
            mix[i] += (2.0 * ph - 1.0 - polyBLEP(ph, dt)) * env
            ph += dt
            if ph >= 1.0 { ph -= 1.0 }
        }
    }
    var lp = Biquad(.lowpass, freq: 1200, q: qDB(1))
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n { out[i] = Float(lp.process(mix[i])) }
    return out
}

private func fxSplash(freq: Double) -> [Float] {
    let n = Int(0.4 * kSampleRate)
    var bp = Biquad(.bandpass, freq: freq, q: 0.8)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let env = pow(1.0 - Double(i) / Double(n), 2.6)
        out[i] = Float(bp.process(Double.random(in: -1.0...1.0) * env))
    }
    return out
}

private func fxThunder(rate: Double) -> [Float] {
    let n = Int(kSampleRate * 3.2)
    var base = [Double](repeating: 0, count: n)
    var v = 0.0
    for i in 0..<n {
        v = v * 0.992 + Double.random(in: -1.0...1.0) * 0.09
        let t = Double(i) / Double(n)
        base[i] = v * min(1.0, t * 25.0) * pow(1.0 - t, 1.5) * (0.7 + 0.3 * sin(t * 23.0))
    }
    // Resample like AudioBufferSourceNode.playbackRate, then lowpass 260 and gain 1.4.
    let m = Int(Double(n) / rate)
    var lp = Biquad(.lowpass, freq: 260, q: qDB(1))
    var out = [Float](repeating: 0, count: m)
    for j in 0..<m {
        let pos = Double(j) * rate
        let i0 = min(n - 1, Int(pos))
        let i1 = min(n - 1, i0 + 1)
        let fr = pos - Double(i0)
        let x = base[i0] * (1.0 - fr) + base[i1] * fr
        out[j] = Float(lp.process(x) * 1.4)
    }
    return out
}

private func fxApplause() -> [Float] {
    let sr = kSampleRate
    let n = Int(sr * 3.6)
    var raw = [Double](repeating: 0, count: n)
    for _ in 0..<1100 {
        let s0 = Int(pow(Double.random(in: 0.0..<1.0), 1.3) * 3.2 * sr)
        let len = max(1, Int(sr * (0.006 + Double.random(in: 0.0..<1.0) * 0.01)))
        let a = 0.15 + Double.random(in: 0.0..<1.0) * 0.35
        var i = 0
        while i < len && s0 + i < n {
            raw[s0 + i] += Double.random(in: -1.0...1.0) * a * exp(-Double(i) / (Double(len) * 0.3))
            i += 1
        }
    }
    var bp = Biquad(.bandpass, freq: 2000, q: 0.5)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sr
        var m = min(1.0, t / 0.25)
        if t > 2.0 { m *= max(0.0, 1.0 - (t - 2.0) / 1.6) }
        out[i] = Float(bp.process(raw[i] * m) * 0.5)
    }
    return out
}

/// Clamp, apply a 5 ms tail fade (the web hard-stops oscillators; this avoids clicks) and wrap in a PCM buffer.
private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    let n = samples.count
    guard n > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)),
          let dst = buf.floatChannelData?[0] else { return nil }
    buf.frameLength = AVAudioFrameCount(n)
    let fade = min(n, 220)
    for i in 0..<n {
        var v = max(-1.0, min(1.0, samples[i]))
        if i >= n - fade { v *= Float(n - 1 - i) / Float(fade) }
        dst[i] = v
    }
    return buf
}

// MARK: - SoundEngine

@MainActor
final class SoundEngine {
    /// True while the AVAudioEngine is running (and so owns an active audio session). Cox checks this
    /// before deactivating the session.
    private(set) static var isRunning = false

    var effectsEnabled = true {
        didSet {
            guard effectsEnabled != oldValue else { return }
            if !effectsEnabled && graphBuilt {
                for node in pool { node.stop() }
            }
            pushParams()
        }
    }

    var musicEnabled = true {
        didSet {
            guard musicEnabled != oldValue else { return }
            if musicEnabled && musicWanted { ensureRunning() }
            pushParams()
        }
    }

    private let synth = MusicSynth()
    private var engine = AVAudioEngine()
    private var pool: [AVAudioPlayerNode] = []
    private var busyUntil: [TimeInterval] = []
    private var graphBuilt = false
    private var cache: [FxKey: AVAudioPCMBuffer] = [:]
    private var observers: [NSObjectProtocol] = []
    private var configObserver: NSObjectProtocol?

    private var musicWanted = false
    private var rainWanted = false
    private var spm = 20.0
    private var level = 0
    private var lastStartAttempt: TimeInterval = 0
    private static let poolSize = 10

    init() {}

    // MARK: Effects

    func splash(volume: Double) { play(.splash(Int.random(in: 0..<4)), volume: volume) }
    /// `k` is the thunder loudness 0...1 (clamped; the web's 1.4 gain is baked into the sample).
    func thunder(_ k: Double) { play(.thunder(Int.random(in: 0..<3)), volume: k) }
    func plink() { play(.plink) }
    func pop() { play(.pop) }
    func horn() { play(.horn) }
    func tick() { play(.tick) }
    func ding(gold: Bool) { play(gold ? .dingGold : .dingPlain) }
    func thud() { play(.thud) }
    func applause() { play(.applause) }
    func chime() { play(.chime) }

    func setRain(_ on: Bool) {
        rainWanted = on
        if on && effectsEnabled { ensureRunning() }
        pushParams()
    }

    /// Optional: render every effect up front (about tens of ms on the main thread) to avoid first-play hitches.
    func prewarm() {
        var keys: [FxKey] = [.plink, .pop, .horn, .tick, .dingGold, .dingPlain, .thud, .applause, .chime]
        for i in 0..<4 { keys.append(.splash(i)) }
        for i in 0..<3 { keys.append(.thunder(i)) }
        for k in keys { _ = buffer(for: k) }
    }

    // MARK: Music

    func startMusic() {
        musicWanted = true
        if musicEnabled { ensureRunning() }
        pushParams()
    }

    /// Fades out over ~1 s (0.3 s time constant) and then goes silent.
    func stopMusic() {
        musicWanted = false
        pushParams()
    }

    /// Call ~10x per second. Does not start the music by itself.
    func setMusic(strokeRate: Double, level: Int) {
        spm = (strokeRate.isFinite && strokeRate > 0) ? strokeRate : 20.0
        self.level = min(3, max(0, level))
        pushParams()
        if musicWanted && musicEnabled && graphBuilt && !engine.isRunning {
            // Recover after an interruption / route change, throttled to once per second.
            if ProcessInfo.processInfo.systemUptime - lastStartAttempt > 1.0 { ensureRunning() }
        }
    }

    /// Pause the engine and release the session (e.g. when the app goes to the background).
    /// The next effect or setMusic call restarts it.
    func suspend() {
        guard graphBuilt else { return }
        for node in pool { node.stop() }
        engine.pause()
        SoundEngine.isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Engine plumbing

    private func pushParams() {
        let p = MusicParams(on: musicWanted && musicEnabled,
                            spm: spm,
                            level: level,
                            rain: (rainWanted && effectsEnabled) ? 0.05 : 0.0)
        synth.params.withLock { $0 = p }
    }

    private func buffer(for key: FxKey) -> AVAudioPCMBuffer? {
        if let b = cache[key] { return b }
        guard let b = makeBuffer(renderFx(key)) else { return nil }
        cache[key] = b
        return b
    }

    private func play(_ key: FxKey, volume: Double = 1.0) {
        guard effectsEnabled, let buf = buffer(for: key), ensureRunning() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var idx = 0
        var soonest = Double.greatestFiniteMagnitude
        for i in 0..<pool.count {
            if busyUntil[i] <= now {
                idx = i
                break
            }
            if busyUntil[i] < soonest {
                soonest = busyUntil[i]
                idx = i
            }
        }
        let node = pool[idx]
        node.stop()
        node.volume = Float(min(1.0, max(0.0, volume)))
        node.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        node.play()
        busyUntil[idx] = now + Double(buf.frameLength) / kSampleRate + 0.05
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }

    @discardableResult
    private func ensureRunning() -> Bool {
        if !graphBuilt { buildGraph() }
        if engine.isRunning {
            SoundEngine.isRunning = true
            return true
        }
        lastStartAttempt = ProcessInfo.processInfo.systemUptime
        configureSession()
        do {
            try engine.start()
            SoundEngine.isRunning = true
            return true
        } catch {
            SoundEngine.isRunning = false
            return false
        }
    }

    private func buildGraph() {
        pool = []
        busyUntil = []
        for _ in 0..<Self.poolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: monoFormat)
            pool.append(node)
            busyUntil.append(0)
        }
        let src = AVAudioSourceNode(format: monoFormat, renderBlock: Self.makeRenderBlock(synth))
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: monoFormat)
        engine.prepare()
        graphBuilt = true

        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigChange() }
        }
        if observers.isEmpty { registerSessionObservers() }
    }

    private func registerSessionObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let t = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let o = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor in self?.handleInterruption(type: t, options: o) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(type: UInt?, options: UInt) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            SoundEngine.isRunning = false
        case .ended:
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                ensureRunning()
            }
        @unknown default:
            break
        }
    }

    private func handleConfigChange() {
        SoundEngine.isRunning = engine.isRunning
        if !engine.isRunning { ensureRunning() }
    }

    private func handleMediaServicesReset() {
        SoundEngine.isRunning = false
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        engine.stop()
        engine = AVAudioEngine()
        graphBuilt = false
        if musicWanted || rainWanted { ensureRunning() }
    }

    /// Built in a nonisolated context so the closure is not main-actor isolated (it runs on the audio thread).
    private nonisolated static func makeRenderBlock(_ synth: MusicSynth) -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = abl.first, let data = first.mData else { return noErr }
            let frames = Int(frameCount)
            synth.render(frames: frames, out: data.assumingMemoryBound(to: Float.self))
            if abl.count > 1 {
                for k in 1..<abl.count {
                    if let d = abl[k].mData {
                        memcpy(d, data, frames * MemoryLayout<Float>.size)
                    }
                }
            }
            return noErr
        }
    }
}
