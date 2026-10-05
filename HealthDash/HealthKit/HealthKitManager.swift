import Foundation
import HealthKit

/// Writes HealthDash readings into Apple Health (write-only).
/// Everything the app measures becomes visible to the rest of iOS —
/// the Health app, watch complications, and any other app Drew uses —
/// while HealthDash stays the single collector.
///
/// Only *new* samples are written: history sync dedups before persist,
/// so a re-sync never double-writes.
final class HealthKitManager {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        for id in [HKQuantityTypeIdentifier.bodyMass,
                   .stepCount, .heartRate, .oxygenSaturation,
                   .heartRateVariabilitySDNN, .bodyTemperature,
                   .activeEnergyBurned, .distanceWalkingRunning] as [HKQuantityTypeIdentifier] {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }

    func requestAuthorization() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: [])
        } catch {
            // Authorization is best-effort; the app works fully without it.
        }
    }

    // MARK: - Writers

    func saveWeight(kg: Double, at date: Date) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return }
        let q = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg)
        save([HKQuantitySample(type: type, quantity: q, start: date, end: date)])
    }

    /// One HKSample per ring event. Cumulative day counters (stepsTotal) are
    /// deliberately skipped — HealthKit sums samples, so only additive
    /// interval buckets are written.
    func samples(for event: RingEvent) -> [HKSample] {
        switch event {
        case .stepsBucket(let steps, let dist, let at):
            return [quantity(.stepCount, Double(steps), .count(), at),
                    quantity(.distanceWalkingRunning, dist, .meter(), at)]
                .compactMap { $0 }
        case .heartRate(let bpm, let at):
            // HK wants count/min.
            return [quantity(.heartRate, Double(bpm), HKUnit.count().unitDivided(by: .minute()), at)]
                .compactMap { $0 }
        case .spo2(let pct, let at):
            return [quantity(.oxygenSaturation, Double(pct) / 100.0, .percent(), at)]
                .compactMap { $0 }
        case .hrv(let ms, let at):
            return [quantity(.heartRateVariabilitySDNN, ms, .secondUnit(with: .milli), at)]
                .compactMap { $0 }
        case .temperature(let c, let at):
            return [quantity(.bodyTemperature, c, .degreeCelsius(), at)]
                .compactMap { $0 }
        case .sleep(let start, let stages):
            return sleepSamples(start: start, stages: stages)
        default:
            return []
        }
    }

    func save(_ samples: [HKSample]) {
        guard !samples.isEmpty, isAvailable else { return }
        store.save(samples) { _, _ in }
    }

    // MARK: - Helpers

    private func quantity(_ id: HKQuantityTypeIdentifier, _ value: Double,
                          _ unit: HKUnit, _ date: Date) -> HKSample? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                start: date, end: date)
    }

    /// Coalesce per-minute stages into intervals — one sample per unbroken run.
    private func sleepSamples(start: Date, stages: [UInt8]) -> [HKSample] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        var out: [HKSample] = []
        var runStage: UInt8? = nil
        var runStart = start
        func flush(_ stage: UInt8, from: Date, to: Date) {
            guard from < to, let value = sleepValue(stage) else { return }
            out.append(HKCategorySample(type: type, value: value.rawValue, start: from, end: to))
        }
        for (i, stage) in stages.enumerated() {
            let t = start.addingTimeInterval(Double(i) * 60)
            if stage != runStage {
                if let rs = runStage { flush(rs, from: runStart, to: t) }
                runStage = stage
                runStart = t
            }
        }
        if let rs = runStage {
            flush(rs, from: runStart, to: start.addingTimeInterval(Double(stages.count) * 60))
        }
        return out
    }

    private func sleepValue(_ stage: UInt8) -> HKCategoryValueSleepAnalysis? {
        switch stage {
        case 1: return .asleepDeep
        case 2: return .asleepCore
        case 3: return .asleepREM
        case 4: return .awake
        default: return .asleepUnspecified
        }
    }
}
