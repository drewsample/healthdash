import Foundation
import SwiftData

// MARK: - Scale

@Model
final class WeightReading {
    var timestamp: Date
    var kg: Double
    var impedanceOhms: Double?   // nil when the scale broadcast weight only
    var source: String           // "okok"

    init(timestamp: Date = Date(), kg: Double, impedanceOhms: Double? = nil, source: String = "okok") {
        self.timestamp = timestamp
        self.kg = kg
        self.impedanceOhms = impedanceOhms
        self.source = source
    }
}

// MARK: - Ring metrics

/// One decoded ring sample. History samples upsert on (kind, timestamp);
/// live samples append. The ring replays its whole log every sync, so the
/// upsert key is what keeps re-syncs idempotent.
@Model
final class MetricSample {
    var timestamp: Date
    var kindRaw: String
    var value: Double
    var source: String   // "ring-live" | "ring-history"

    init(timestamp: Date, kind: SampleKind, value: Double, source: String) {
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.value = value
        self.source = source
    }

    var kind: SampleKind { SampleKind(rawValue: kindRaw) ?? .unknown }
}

enum SampleKind: String, Codable, CaseIterable {
    case stepsBucket     // additive interval buckets (05 02 sport history)
    case stepsTotal      // cumulative day counter (06 00 live push)
    case distanceM
    case caloriesActive  // ring's own active-calorie estimate
    case heartRate
    case spo2
    case hrv
    case respiratoryRate
    case temperature
    case systolic
    case diastolic
    case battery
    case unknown
}

// MARK: - Sleep

/// One night, stored as per-minute stage bytes (1 deep, 2 light, 3 REM, 4 awake).
@Model
final class SleepSession {
    var start: Date
    var end: Date
    var stages: Data   // one byte per minute

    init(start: Date, end: Date, stages: Data) {
        self.start = start
        self.end = end
        self.stages = stages
    }

    var minutesByStage: [Int: Int] {
        var counts: [Int: Int] = [:]
        for b in stages { counts[Int(b), default: 0] += 1 }
        return counts
    }

    var totalMinutes: Int { stages.count }
}

// MARK: - User profile (single row, edited in Settings)

@Model
final class Profile {
    var age: Int
    var isMale: Bool
    var heightCm: Double
    var calorieGoal: Int      // daily total target, kcal
    var usePounds: Bool

    init(age: Int = 40, isMale: Bool = true, heightCm: Double = 178,
         calorieGoal: Int = 2200, usePounds: Bool = true) {
        self.age = age
        self.isMale = isMale
        self.heightCm = heightCm
        self.calorieGoal = calorieGoal
        self.usePounds = usePounds
    }
}
