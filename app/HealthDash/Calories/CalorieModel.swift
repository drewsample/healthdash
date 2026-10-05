import Foundation

/// Transparent calorie math. Everything here is an *estimate*, and the UI
/// labels it as such — the ring measures steps and heart rate, not energy.
///
/// - BMR: Mifflin-St Jeor, from profile + latest scale weight.
/// - Active: the ring's own active-calorie counter (06 00 live ratchet),
///   falling back to a steps-based estimate when the ring reports none.
/// - Total: BMR + active.
enum CalorieModel {
    static func bmr(profile: Profile, weightKg: Double) -> Double {
        let w = weightKg, h = profile.heightCm, a = Double(profile.age)
        return profile.isMale
            ? 10 * w + 6.25 * h - 5 * a + 5
            : 10 * w + 6.25 * h - 5 * a - 161
    }

    /// Ring-reported active calories for a day (the 06 00 cumulative counter).
    static func ringActiveCalories(on day: Date, in samples: [MetricSample]) -> Double {
        let start = Calendar.current.startOfDay(for: day)
        return samples
            .filter { $0.kind == .caloriesActive && Calendar.current.isDate($0.timestamp, inSameDayAs: start) }
            .map(\.value).max() ?? 0
    }

    /// Fallback: ~0.04 kcal per step for an ~100 kg adult walking.
    /// Crude — only used when the ring hasn't reported its own number.
    static func stepsFallbackCalories(steps: Int, weightKg: Double) -> Double {
        Double(steps) * 0.0004 * weightKg
    }

    static func activeCalories(steps: Int, ringCalories: Double, weightKg: Double) -> Double {
        ringCalories > 0 ? ringCalories : stepsFallbackCalories(steps: steps, weightKg: weightKg)
    }

    static func todaySteps(in samples: [MetricSample]) -> Int {
        let start = Calendar.current.startOfDay(for: Date())
        let live = samples
            .filter { $0.kind == .stepsTotal && Calendar.current.isDate($0.timestamp, inSameDayAs: start) }
            .map(\.value).max() ?? 0
        let buckets = samples
            .filter { $0.kind == .stepsBucket && $0.timestamp >= start }
            .map(\.value).reduce(0, +)
        return Int(max(live, buckets))
    }
}
