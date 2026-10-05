import Foundation
import CoreBluetooth
import SwiftData

/// Passive listener for the OKOK scale. The scale broadcasts weight in its
/// advertisements, so no connection or pairing is ever needed — just scan.
///
/// Live readings update `currentKg` immediately; a reading is persisted only
/// when it's stable-different from the last stored one (avoids flooding the
/// store with one row per advertisement).
///
/// Not @MainActor: see RingManager — same CoreBluetooth delegate constraint.
final class ScaleScanner: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var currentKg: Double?
    @Published var currentImpedance: Double?
    @Published var lastVariant: String?
    @Published var bluetoothState: CBManagerState = .unknown

    private var central: CBCentralManager!
    private var modelContext: ModelContext?
    private var lastPersistedKg: Double?
    private var lastPersistedAt: Date?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func attach(_ context: ModelContext) { modelContext = context }

    func start() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
    }

    func stop() {
        central.stopScan()
        isScanning = false
    }

    private func handleAdvertisement(_ advertisementData: [String: Any]) {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let reading = OKOKAdvertParser.parse(mfg) else { return }
        currentKg = reading.kg
        currentImpedance = reading.impedanceOhms
        lastVariant = reading.variant
        persistIfNew(reading)
    }

    private func persistIfNew(_ reading: OKOKAdvertParser.Reading) {
        let now = Date()
        // Same weight seen recently — don't write another row.
        if let lastKg = lastPersistedKg, let lastAt = lastPersistedAt,
           abs(lastKg - reading.kg) < 0.05, now.timeIntervalSince(lastAt) < 120 { return }
        lastPersistedKg = reading.kg
        lastPersistedAt = now
        if let ctx = modelContext {
            MainActor.assumeIsolated {
                ctx.insert(WeightReading(timestamp: now, kg: reading.kg,
                                         impedanceOhms: reading.impedanceOhms))
                try? ctx.save()
            }
        }
        HealthKitManager.shared.saveWeight(kg: reading.kg, at: now)
    }
}

extension ScaleScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn, isScanning { start() }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        handleAdvertisement(advertisementData)
    }
}
