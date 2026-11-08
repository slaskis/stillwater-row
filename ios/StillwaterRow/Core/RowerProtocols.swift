import Foundation

/// One update from a rowing console. Fields are nil when a frame doesn't carry them.
struct RowerSample: Equatable {
    var strokeRate: Double? = nil
    var power: Double? = nil
    var distance: Double? = nil
    var strokes: Int? = nil
    var pace: Double? = nil        // seconds per 500 m
}

/// FitShow consoles ("FS-…", service FFF0), as on the Trekkrunner TR020.
/// Frames are `02 <cmd> <payload…> <xor of cmd+payload> 03`. The console only answers when polled.
/// Byte layout follows the FitShow rower driver in qdomyos-zwift, and matches what the web app read from the TR020.
enum FitShow {
    static let initFrames: [[UInt8]] = [
        [0x02, 0x41, 0x02, 0x43, 0x03],
        [0x02, 0x41, 0x02, 0x43, 0x03],
        [0x02, 0x43, 0x01, 0x42, 0x03],
        [0x02, 0x42, 0x42, 0x03],
        [0x02, 0x44, 0x01, 0x45, 0x03],
        [0x02, 0x44, 0x02, 0x46, 0x03],
    ]
    static let statusFrame: [UInt8] = [0x02, 0x42, 0x42, 0x03]
    static let totalsFrame: [UInt8] = [0x02, 0x43, 0x01, 0x42, 0x03]

    /// Frame to send on poll number `step` (every 0.5 s): the init sequence, then status and totals alternately.
    static func pollFrame(step: Int) -> [UInt8] {
        if step < initFrames.count { return initFrames[step] }
        return (step - initFrames.count) % 2 == 0 ? statusFrame : totalsFrame
    }

    static func decode(_ f: [UInt8]) -> RowerSample? {
        guard f.count >= 4 else { return nil }
        func le16(_ o: Int) -> Int { Int(f[o]) | (Int(f[o + 1]) << 8) }
        switch f[1] {
        case 0x42 where f.count == 15:
            let running = f[2] == 0x02
            return RowerSample(strokeRate: running ? Double(le16(6)) : 0,
                               power: running ? Double(le16(9)) / 10 : 0)
        case 0x43 where f.count == 13 && f[2] == 0x01:
            let raw = le16(5)
            let metres = Double(raw & 0x7fff) * ((raw & 0x8000) != 0 ? 10 : 1)
            return RowerSample(distance: metres, strokes: le16(9))
        default:
            return nil
        }
    }
}

/// Reassembles FitShow frames from notifications, which can split or join frames.
struct FitShowDecoder {
    private var buffer: [UInt8] = []

    mutating func reset() { buffer.removeAll() }

    mutating func feed(_ bytes: [UInt8]) -> [RowerSample] {
        buffer.append(contentsOf: bytes)
        var out: [RowerSample] = []
        while !buffer.isEmpty {
            guard let start = buffer.firstIndex(of: 0x02) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            var found = false
            var end = 3
            while end < buffer.count {
                if buffer[end] == 0x03 {
                    var x: UInt8 = 0
                    for k in 1..<(end - 1) { x ^= buffer[k] }
                    if x == buffer[end - 1] {
                        let frame = Array(buffer[0...end])
                        buffer.removeFirst(end + 1)
                        if let s = FitShow.decode(frame) { out.append(s) }
                        found = true
                        break
                    }
                }
                end += 1
            }
            if !found {
                if buffer.count > 64 { buffer.removeFirst() } else { break }
            }
        }
        return out
    }
}

/// Standard Bluetooth Fitness Machine Service, Rower Data characteristic (0x2AD1).
enum FTMS {
    static func decodeRowerData(_ d: [UInt8]) -> RowerSample? {
        guard d.count >= 2 else { return nil }
        let flags = Int(d[0]) | (Int(d[1]) << 8)
        var i = 2
        var s = RowerSample()
        if flags & 1 == 0, i + 3 <= d.count {
            s.strokeRate = Double(d[i]) / 2
            s.strokes = Int(d[i + 1]) | (Int(d[i + 2]) << 8)
            i += 3
        }
        if flags & 2 != 0 { i += 1 }                       // average stroke rate
        if flags & 4 != 0, i + 3 <= d.count {
            s.distance = Double(Int(d[i]) | (Int(d[i + 1]) << 8) | (Int(d[i + 2]) << 16))
            i += 3
        }
        if flags & 8 != 0, i + 2 <= d.count {
            s.pace = Double(Int(d[i]) | (Int(d[i + 1]) << 8))
            i += 2
        }
        if flags & 16 != 0 { i += 2 }                      // average pace
        if flags & 32 != 0, i + 2 <= d.count {
            s.power = Double(Int16(bitPattern: UInt16(d[i]) | (UInt16(d[i + 1]) << 8)))
            i += 2
        }
        return s
    }
}

/// Standard Heart Rate Measurement characteristic (0x2A37), from chest straps and arm bands.
enum HeartRateMeasurement {
    static func decode(_ d: [UInt8]) -> Int? {
        guard d.count >= 2 else { return nil }
        if d[0] & 1 == 0 { return Int(d[1]) }
        guard d.count >= 3 else { return nil }
        return Int(d[1]) | (Int(d[2]) << 8)
    }
}

/// Keeps a running console distance across console resets and derives speed from it,
/// since FitShow consoles don't report pace.
struct ConsoleTracker {
    private(set) var total: Double = 0
    private(set) var derivedSpeed: Double = 0
    private var base: Double = 0
    private var lastRaw: Double = 0
    private var history: [(t: Double, d: Double)] = []

    mutating func reset() {
        total = 0
        derivedSpeed = 0
        base = 0
        lastRaw = 0
        history.removeAll()
    }

    mutating func update(raw: Double, at now: Double) {
        if raw < lastRaw - 5 { base += lastRaw }       // console was reset
        lastRaw = raw
        total = base + raw
        history.append((now, total))
        while history.count > 2, now - history[0].t > 6 { history.removeFirst() }
        if let a = history.first, let b = history.last, b.t - a.t > 1.5 {
            derivedSpeed = (b.d - a.d) / (b.t - a.t)
        }
    }
}
