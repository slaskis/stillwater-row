import CoreBluetooth
import Foundation
import Observation
import QuartzCore

enum BLE {
    static let fitShowService = CBUUID(string: "FFF0")
    static let fitShowNotify = CBUUID(string: "FFF1")
    static let fitShowWrite = CBUUID(string: "FFF2")
    static let ftmsService = CBUUID(string: "1826")
    static let rowerData = CBUUID(string: "2AD1")
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")
}

struct FoundDevice: Identifiable, Equatable {
    enum Kind { case rower, heartRate }
    let id: UUID
    var name: String
    var kind: Kind
    var rssi: Int
}

enum RowerProtocol { case fitShow, ftms }

/// Talks to the rowing console (FitShow or FTMS) and, optionally, a Bluetooth heart-rate strap.
/// Remembers both and reconnects on its own whenever they are in range.
@MainActor @Observable
final class BluetoothLink: NSObject {
    var problem: String?
    var scanning = false
    var found: [FoundDevice] = []

    var rowerName: String?
    var rowerConnecting = false
    var rowerProtocol: RowerProtocol?
    var receiving = false
    var strokeRate: Double = 0
    var power: Double = 0
    var pace: Double = 0
    var consoleDistance: Double = 0
    var derivedSpeed: Double = 0

    var heartRateName: String?
    var heartRate: Int?

    var rowerReady: Bool { rowerProtocol != nil && receiving }

    @ObservationIgnored var onStroke: (() -> Void)?
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var known: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var rower: CBPeripheral?
    @ObservationIgnored private var strap: CBPeripheral?
    @ObservationIgnored private var writeChar: CBCharacteristic?
    @ObservationIgnored private var decoder = FitShowDecoder()
    @ObservationIgnored private var tracker = ConsoleTracker()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var pollStep = 0
    @ObservationIgnored private var lastStrokes = -1
    @ObservationIgnored private var wantScan = false
    @ObservationIgnored private var scanStopToken = 0

    private static let rowerKey = "bt.rower"
    private static let strapKey = "bt.strap"

    /// Reconnects to remembered devices. Doesn't trigger the Bluetooth prompt for first-time users.
    func resume() {
        let d = UserDefaults.standard
        if d.string(forKey: Self.rowerKey) != nil || d.string(forKey: Self.strapKey) != nil { ensureCentral() }
    }

    func startScan() {
        wantScan = true
        found.removeAll()
        ensureCentral()
        if central?.state == .poweredOn { beginScan() }
    }

    func stopScan() {
        wantScan = false
        central?.stopScan()
        scanning = false
    }

    func connect(_ device: FoundDevice) {
        guard let central, let p = known[device.id] else { return }
        stopScan()
        p.delegate = self
        switch device.kind {
        case .rower:
            if let old = rower, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
            rower = p
            rowerName = device.name
            rowerConnecting = true
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.rowerKey)
        case .heartRate:
            if let old = strap, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
            strap = p
            heartRateName = device.name
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.strapKey)
        }
        central.connect(p, options: nil)
    }

    func forgetRower() {
        UserDefaults.standard.removeObject(forKey: Self.rowerKey)
        if let rower { central?.cancelPeripheralConnection(rower) }
        rower = nil
        rowerName = nil
        clearRowerState()
    }

    func forgetStrap() {
        UserDefaults.standard.removeObject(forKey: Self.strapKey)
        if let strap { central?.cancelPeripheralConnection(strap) }
        strap = nil
        heartRateName = nil
        heartRate = nil
    }

    // MARK: - Internals

    private func ensureCentral() {
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
    }

    private func beginScan() {
        guard let central else { return }
        central.scanForPeripherals(withServices: [BLE.fitShowService, BLE.ftmsService, BLE.heartRateService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        scanStopToken += 1
        let token = scanStopToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.scanStopToken == token, self.scanning else { return }
            self.stopScan()
        }
    }

    private func reconnectRemembered() {
        guard let central else { return }
        let d = UserDefaults.standard
        if rower == nil, let s = d.string(forKey: Self.rowerKey), let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            rower = p
            rowerName = p.name ?? "Rower"
            rowerConnecting = true
            p.delegate = self
            central.connect(p, options: nil)
        }
        if strap == nil, let s = d.string(forKey: Self.strapKey), let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            strap = p
            heartRateName = p.name ?? "Heart-rate strap"
            p.delegate = self
            central.connect(p, options: nil)
        }
    }

    private func stateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            problem = nil
            reconnectRemembered()
            if wantScan { beginScan() }
        case .poweredOff:
            problem = "Bluetooth is off. Turn it on in Control Center."
            dropConnections()
        case .unauthorized:
            problem = "Stillwater isn't allowed to use Bluetooth. Turn it on in Settings › Stillwater."
            dropConnections()
        case .resetting:
            dropConnections()
        case .unsupported:
            problem = "This device doesn't support Bluetooth LE."
        default:
            break
        }
    }

    /// CoreBluetooth drops everything without disconnect callbacks; forget the live peripherals
    /// (but not the remembered ids) so they reconnect when Bluetooth is back.
    private func dropConnections() {
        clearRowerState()
        rower = nil
        strap = nil
        heartRate = nil
        scanning = false
    }

    private func discovered(_ p: CBPeripheral, advertisement: [String: Any], rssi: Int) {
        let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = p.name ?? advertisement[CBAdvertisementDataLocalNameKey] as? String ?? "Unnamed device"
        let kind: FoundDevice.Kind
        if services.contains(BLE.heartRateService) { kind = .heartRate }
        else if services.contains(BLE.fitShowService) || services.contains(BLE.ftmsService) || name.hasPrefix("FS-") { kind = .rower }
        else { return }
        known[p.identifier] = p
        if let i = found.firstIndex(where: { $0.id == p.identifier }) {
            found[i].rssi = rssi
            found[i].name = name
        } else {
            found.append(FoundDevice(id: p.identifier, name: name, kind: kind, rssi: rssi))
        }
    }

    private func didConnect(_ p: CBPeripheral) {
        if p.identifier == rower?.identifier {
            rowerConnecting = false
            p.discoverServices([BLE.fitShowService, BLE.ftmsService])
        } else if p.identifier == strap?.identifier {
            p.discoverServices([BLE.heartRateService])
        }
    }

    private func didDisconnect(_ p: CBPeripheral) {
        if p.identifier == rower?.identifier {
            clearRowerState()
            rowerConnecting = true
            central?.connect(p, options: nil)          // waits until the console wakes up again
        } else if p.identifier == strap?.identifier {
            heartRate = nil
            central?.connect(p, options: nil)
        }
    }

    private func clearRowerState() {
        pollTimer?.invalidate()
        pollTimer = nil
        writeChar = nil
        rowerProtocol = nil
        rowerConnecting = false
        receiving = false
        strokeRate = 0
        power = 0
        pace = 0
        derivedSpeed = 0
        decoder.reset()
        lastStrokes = -1
    }

    private func setUp(_ p: CBPeripheral, service: CBService) {
        let chars = service.characteristics ?? []
        if service.uuid == BLE.fitShowService {
            for c in chars {
                if c.uuid == BLE.fitShowNotify { p.setNotifyValue(true, for: c) }
                if c.uuid == BLE.fitShowWrite { writeChar = c }
            }
            if writeChar != nil {
                rowerProtocol = .fitShow
                startPolling()
            }
        } else if service.uuid == BLE.ftmsService {
            if let c = chars.first(where: { $0.uuid == BLE.rowerData }), rowerProtocol != .fitShow {
                p.setNotifyValue(true, for: c)
                rowerProtocol = .ftms
            }
        } else if service.uuid == BLE.heartRateService {
            if let c = chars.first(where: { $0.uuid == BLE.heartRateMeasurement }) { p.setNotifyValue(true, for: c) }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollStep = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard let rower, let c = writeChar, rower.state == .connected else { return }
        let frame = FitShow.pollFrame(step: pollStep)
        pollStep += 1
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        rower.writeValue(Data(frame), for: c, type: type)
    }

    private func received(_ bytes: [UInt8], uuid: CBUUID) {
        switch uuid {
        case BLE.fitShowNotify:
            for s in decoder.feed(bytes) { apply(s) }
        case BLE.rowerData:
            if let s = FTMS.decodeRowerData(bytes) { apply(s) }
        case BLE.heartRateMeasurement:
            heartRate = HeartRateMeasurement.decode(bytes)
        default:
            break
        }
    }

    private func apply(_ s: RowerSample) {
        receiving = true
        if let v = s.strokeRate { strokeRate = v }
        if let v = s.power { power = v }
        if let v = s.pace { pace = v }
        if let d = s.distance {
            tracker.update(raw: d, at: CACurrentMediaTime())
            consoleDistance = tracker.total
            derivedSpeed = tracker.derivedSpeed
        }
        if let n = s.strokes {
            if lastStrokes >= 0 && n > lastStrokes { onStroke?() }
            lastStrokes = n
        }
    }
}

extension BluetoothLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { self.stateChanged(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { self.discovered(peripheral, advertisement: advertisementData, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.didConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.didDisconnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { self.didDisconnect(peripheral) }
    }
}

extension BluetoothLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { self.setUp(peripheral, service: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let bytes = [UInt8](characteristic.value ?? Data())
        let uuid = characteristic.uuid
        MainActor.assumeIsolated { self.received(bytes, uuid: uuid) }
    }
}
