import Foundation
import CoreBluetooth
import SwiftData
import HealthKit

struct ScannedDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    var looksLikeRing: Bool
}

/// Owns the TK5 ring link: scan → connect → handshake → live stream → history
/// sync. All YCBT wire details live in YCBT.swift / YCBTCommands / YCBTDecoder;
/// this is the CoreBluetooth state machine and the SwiftData sink.
@MainActor
final class RingManager: NSObject, ObservableObject {
    enum State: String {
        case idle, scanning, connecting, syncing, ready
    }

    @Published var state: State = .idle
    @Published var discovered: [ScannedDevice] = []
    @Published var connectedName: String?
    @Published var battery: Int?
    @Published var lastSync: Date?
    @Published var syncDetail: String = ""
    @Published var liveHeartRate: Int?
    @Published var liveSteps: Int?
    @Published var errorMessage: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var cmdChar: CBCharacteristic?
    private var streamChar: CBCharacteristic?
    private let assembler = YCBTFrameAssembler()

    // Command pump
    private var queue: [[UInt8]] = []
    private var awaiting: (type: UInt8, cmd: UInt8)?
    private var replyTimer: Timer?

    // History transfer
    private var syncTypes: [YCBTHistoryType] = []
    private var activeType: YCBTHistoryType?
    private var transferBuffer: [UInt8] = []

    // Spot measurement
    private var spotMode: UInt8?
    private var spotTimer: Timer?
    var onSpotResult: ((String, Double) -> Void)?

    private var modelContext: ModelContext?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "com.healthdash.ring-restore"])
    }

    func attach(_ context: ModelContext) {
        modelContext = context
    }

    /// The profile row, read fresh at handshake time (it may be created after attach).
    private func currentProfile() -> Profile? {
        guard let ctx = modelContext else { return nil }
        var d = FetchDescriptor<Profile>()
        d.fetchLimit = 1
        return try? ctx.fetch(d).first
    }

    // MARK: - Scan / connect

    func startScan() {
        guard central.state == .poweredOn else {
            errorMessage = "Bluetooth is not on."
            return
        }
        discovered.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ device: ScannedDevice) {
        guard let p = peripheralsById[device.id] else { return }
        stopScan()
        state = .connecting
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        reset()
    }

    private func reset() {
        queue.removeAll(); syncTypes.removeAll(); activeType = nil
        transferBuffer.removeAll(); cmdChar = nil; streamChar = nil
        peripheral = nil; connectedName = nil
        assembler.reset(); replyTimer?.invalidate()
        if state != .scanning { state = .idle }
    }

    // MARK: - Command pump

    private func enqueue(_ commands: [[UInt8]]) {
        queue.append(contentsOf: commands)
        pump()
    }

    private func pump() {
        guard awaiting == nil, !queue.isEmpty, let char = cmdChar, let p = peripheral else { return }
        let logical = queue.removeFirst()
        let frame = YCBTFrame.frame(logical)
        awaiting = (logical[0], logical[1])
        p.writeValue(frame, for: char, type: .withResponse)
        armReplyTimer()
    }

    private func armReplyTimer() {
        replyTimer?.invalidate()
        replyTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.onReplyTimeout() }
        }
    }

    private func onReplyTimeout() {
        // The ring didn't answer; move on rather than wedging the queue.
        // History transfers end via their 05 80 terminal, not this timer.
        if activeType == nil {
            awaiting = nil
            pump()
        }
    }

    private func writeNow(_ logical: [UInt8]) {
        guard let char = cmdChar, let p = peripheral else { return }
        p.writeValue(YCBTFrame.frame(logical), for: char, type: .withResponse)
    }

    // MARK: - Sync

    func syncNow() {
        guard state == .ready else { return }
        state = .syncing
        syncTypes = YCBTHistoryType.syncSet
        startNextHistoryType()
    }

    private func startNextHistoryType() {
        guard !syncTypes.isEmpty else {
            activeType = nil
            state = .ready
            lastSync = Date()
            syncDetail = ""
            try? modelContext?.save()
            return
        }
        activeType = syncTypes.removeFirst()
        transferBuffer.removeAll()
        if let t = activeType {
            syncDetail = "Syncing \(t.label)…"
            awaiting = nil   // terminal frame ends this, not the reply timer
            replyTimer?.invalidate()
            writeNow(YCBTCommands.historyRequest(t))
            // Safety: if no terminal arrives in 20s, move on.
            replyTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finishHistoryType() }
            }
        }
    }

    private func finishHistoryType() {
        replyTimer?.invalidate()
        if let t = activeType, !transferBuffer.isEmpty {
            let events = YCBTDecoder.decodeHistory(transferBuffer, type: t)
            persist(events, source: "ring-history")
        }
        activeType = nil
        startNextHistoryType()
    }

    // MARK: - Spot measurement

    func measureHeartRate() { spotMeasure(mode: YCBTMeasurementMode.heartRate, label: "Heart rate") }
    func measureSpo2() { spotMeasure(mode: YCBTMeasurementMode.spo2, label: "SpO₂") }

    private func spotMeasure(mode: UInt8, label: String) {
        guard state == .ready else { return }
        spotMode = mode
        syncDetail = "Measuring \(label)…"
        writeNow(YCBTCommands.liveMeasurement(enable: true, mode: mode))
        spotTimer?.invalidate()
        spotTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopSpotMeasure() }
        }
    }

    private func stopSpotMeasure() {
        spotTimer?.invalidate()
        if let mode = spotMode { writeNow(YCBTCommands.liveMeasurement(enable: false, mode: mode)) }
        spotMode = nil
        if state == .ready { syncDetail = "" }
    }

    // MARK: - Inbound frames

    private func handleFrame(_ frame: YCBTFrame, from uuid: CBUUID) {
        // Device→app pushes get an immediate ACK; the ring retransmits otherwise.
        if frame.type == YCBTGroup.devControl {
            writeNow(YCBTCommands.pushAck(key: frame.cmd))
            return
        }

        // History transfer frames.
        if frame.type == YCBTGroup.health {
            handleHealthFrame(frame)
            return
        }

        // Live stream.
        if frame.type == YCBTGroup.real {
            let events = YCBTDecoder.decodeLive(frame)
            handleSpotSample(events)
            persist(events, source: "ring-live")
            for e in events {
                switch e {
                case .heartRate(let bpm, _): liveHeartRate = bpm
                case .stepsTotal(let steps, _, _, _): liveSteps = steps
                case .battery(let pct): battery = pct
                default: break
                }
            }
            return
        }

        // Command replies.
        if frame.type == YCBTGroup.get {
            for e in YCBTDecoder.decodeGetReply(frame) {
                if case .battery(let pct) = e { battery = pct }
            }
        }

        if let aw = awaiting, aw.type == frame.type, aw.cmd == frame.cmd {
            awaiting = nil
            replyTimer?.invalidate()
            pump()
        }
    }

    private func handleHealthFrame(_ frame: YCBTFrame) {
        if frame.cmd == YCBTHealth.terminalBlock {
            // [totalPackets:u16][totalBytes:u16][crc16:u16]
            let p = frame.payload
            var ok = false
            if p.count >= 6 {
                let declaredBytes = YCBTBytes.u16(p, 2)
                let crcGiven = UInt16(p[4]) | (UInt16(p[5]) << 8)
                ok = declaredBytes == transferBuffer.count
                    && YCBTFrame.crc16(transferBuffer) == crcGiven
            }
            writeNow(YCBTCommands.historyBlockAck(ok: ok))
            finishHistoryType()
            return
        }
        guard let t = activeType else { return }
        if YCBTFrameError.detect(in: frame.payload) != nil {
            // Unsupported on this firmware — skip the type for this session.
            writeNow(YCBTCommands.historyBlockAck(ok: true))
            finishHistoryType()
            return
        }
        if frame.cmd == t.ackKey {
            // Header (10B: [count:u16][packets:u32][bytes:u32]) vs data chunks.
            if frame.payload.count == 10 {
                let count = YCBTBytes.u16(frame.payload, 0)
                if count == 0 { writeNow(YCBTCommands.historyBlockAck(ok: true)); finishHistoryType() }
            } else if frame.payload.count > 10 {
                transferBuffer.append(contentsOf: frame.payload)
            }
            // ≤9-byte payloads are the ring's "no data" signal: just wait for 05 80.
        }
    }

    private func handleSpotSample(_ events: [RingEvent]) {
        guard let mode = spotMode else { return }
        for e in events {
            switch (mode, e) {
            case (YCBTMeasurementMode.heartRate, .heartRate(let bpm, _)):
                onSpotResult?("Heart rate", Double(bpm)); stopSpotMeasure(); return
            case (YCBTMeasurementMode.spo2, .spo2(let v, _)):
                onSpotResult?("SpO₂", Double(v)); stopSpotMeasure(); return
            default: break
            }
        }
    }

    // MARK: - Persistence

    private func persist(_ events: [RingEvent], source: String) {
        guard let ctx = modelContext else { return }
        let now = Date()
        var hkSamples: [HKSample] = []
        defer { HealthKitManager.shared.save(hkSamples) }
        for e in events {
            // Drop anything absurdly old or from the future (mis-stamped records).
            let ts: Date
            switch e {
            case .stepsTotal(_, _, _, let t): ts = t
            case .stepsBucket(_, _, let t): ts = t
            case .heartRate(_, let t): ts = t
            case .spo2(_, let t): ts = t
            case .hrv(_, let t): ts = t
            case .respiratoryRate(_, let t): ts = t
            case .temperature(_, let t): ts = t
            case .bloodPressure(_, _, let t): ts = t
            case .sleep(let s, _): ts = s
            case .battery: ts = now
            }
            guard ts > now.addingTimeInterval(-8 * 86400), ts < now.addingTimeInterval(3600) else { continue }
            hkSamples.append(contentsOf: HealthKitManager.shared.samples(for: e))

            switch e {
            case .stepsTotal(let steps, let dist, let cal, _):
                let day = Calendar.current.startOfDay(for: ts)
                upsertDaySample(ctx, kind: .stepsTotal, day: day, value: Double(steps), source: source, max: true)
                upsertDaySample(ctx, kind: .distanceM, day: day, value: dist, source: source, max: true)
                upsertDaySample(ctx, kind: .caloriesActive, day: day, value: cal, source: source, max: true)
            case .stepsBucket(let steps, let dist, _):
                insertOnce(ctx, kind: .stepsBucket, timestamp: ts, value: Double(steps), source: source)
                insertOnce(ctx, kind: .distanceM, timestamp: ts, value: dist, source: source)
            case .heartRate(let bpm, _):
                if source == "ring-live" {
                    ctx.insert(MetricSample(timestamp: ts, kind: .heartRate, value: Double(bpm), source: source))
                } else { insertOnce(ctx, kind: .heartRate, timestamp: ts, value: Double(bpm), source: source) }
            case .spo2(let v, _): insertOnce(ctx, kind: .spo2, timestamp: ts, value: Double(v), source: source)
            case .hrv(let ms, _): insertOnce(ctx, kind: .hrv, timestamp: ts, value: ms, source: source)
            case .respiratoryRate(let rpm, _): insertOnce(ctx, kind: .respiratoryRate, timestamp: ts, value: Double(rpm), source: source)
            case .temperature(let c, _): insertOnce(ctx, kind: .temperature, timestamp: ts, value: c, source: source)
            case .bloodPressure(let sys, let dia, _):
                insertOnce(ctx, kind: .systolic, timestamp: ts, value: Double(sys), source: source)
                insertOnce(ctx, kind: .diastolic, timestamp: ts, value: Double(dia), source: source)
            case .sleep(let start, let stages):
                upsertSleep(ctx, start: start, stages: stages)
            case .battery(let pct):
                upsertDaySample(ctx, kind: .battery, day: Calendar.current.startOfDay(for: now),
                               value: Double(pct), source: source, max: false)
            }
        }
    }

    /// Insert unless a sample of the same kind+timestamp already exists.
    private func insertOnce(_ ctx: ModelContext, kind: SampleKind, timestamp: Date, value: Double, source: String) {
        let kindString = kind.rawValue
        var d = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.kindRaw == kindString && $0.timestamp == timestamp })
        d.fetchLimit = 1
        if (try? ctx.fetch(d).isEmpty) ?? true {
            ctx.insert(MetricSample(timestamp: timestamp, kind: kind, value: value, source: source))
        }
    }

    /// One row per kind per day; `max:true` keeps the highest (cumulative counters).
    private func upsertDaySample(_ ctx: ModelContext, kind: SampleKind, day: Date,
                                 value: Double, source: String, max: Bool) {
        let kindString = kind.rawValue
        var d = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.kindRaw == kindString && $0.timestamp == day })
        d.fetchLimit = 1
        if let existing = try? ctx.fetch(d).first {
            existing.value = max ? Swift.max(existing.value, value) : value
        } else {
            ctx.insert(MetricSample(timestamp: day, kind: kind, value: value, source: source))
        }
    }

    private func upsertSleep(_ ctx: ModelContext, start: Date, stages: [UInt8]) {
        let end = start.addingTimeInterval(Double(stages.count) * 60)
        let lo = start.addingTimeInterval(-3600), hi = start.addingTimeInterval(3600)
        var d = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.start > lo && $0.start < hi })
        d.fetchLimit = 1
        if let existing = try? ctx.fetch(d).first {
            existing.stages = Data(stages); existing.end = end
        } else {
            ctx.insert(SleepSession(start: start, end: end, stages: Data(stages)))
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension RingManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn, state == .scanning { state = .idle }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "Unknown"
        peripheralsById[peripheral.identifier] = peripheral
        var looksLikeRing = name.uppercased().hasPrefix("TK5")
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 4 {
            let hex = mfg.prefix(4).map { String(format: "%02x", $0) }.joined()
            if hex.hasPrefix("10786501") { looksLikeRing = true }
        }
        let device = ScannedDevice(id: peripheral.identifier, name: name,
                                   rssi: RSSI.intValue, looksLikeRing: looksLikeRing)
        if let i = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[i] = device
        } else {
            discovered.append(device)
        }
        // Auto-connect to the TK5 — unambiguous name.
        if looksLikeRing, state == .scanning {
            connect(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedName = peripheral.name
        state = .connecting
        syncDetail = "Discovering services…"
        peripheral.discoverServices([YCBTUUIDs.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        errorMessage = "Couldn't connect to the ring."
        reset()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        reset()
    }
}

// MARK: - CBPeripheralDelegate

extension RingManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == YCBTUUIDs.service }) else {
            errorMessage = "Ring doesn't expose the expected service."
            disconnect(); return
        }
        peripheral.discoverCharacteristics([YCBTUUIDs.command, YCBTUUIDs.stream], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == YCBTUUIDs.command { cmdChar = c }
            if c.uuid == YCBTUUIDs.stream { streamChar = c }
        }
        guard cmdChar != nil, streamChar != nil else {
            errorMessage = "Ring is missing protocol channels."
            disconnect(); return
        }
        peripheral.setNotifyValue(true, for: cmdChar!)
        peripheral.setNotifyValue(true, for: streamChar!)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { return }
        // Both channels live → run the handshake.
        if let cmd = cmdChar, let stream = streamChar, cmd.isNotifying, stream.isNotifying,
           queue.isEmpty, awaiting == nil, state == .connecting {
            var commands = YCBTCommands.postSubscriptionHandshake()
            if let profile = currentProfile() {
                commands += YCBTCommands.startupSequence(
                    profile: profile, weightKg: latestWeightKg() ?? 100)
            }
            state = .syncing
            syncDetail = "Handshaking…"
            enqueue(commands)
            // When the queue drains, begin history sync.
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    if self.queue.isEmpty, self.awaiting == nil, self.state == .syncing,
                       self.activeType == nil {
                        t.invalidate()
                        self.state = .ready
                        self.syncNow()
                    }
                }
            }
        }
    }

    private func latestWeightKg() -> Double? {
        guard let ctx = modelContext else { return nil }
        var d = FetchDescriptor<WeightReading>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        d.fetchLimit = 1
        return try? ctx.fetch(d).first?.kg
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Writes are chained on replies, not on write-acks.
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        for frameData in assembler.append(data, from: characteristic.uuid) {
            guard let frame = YCBTFrame(validating: frameData) else { continue }
            handleFrame(frame, from: characteristic.uuid)
        }
    }
}
