import SwiftUI
import SwiftData

@main
struct HealthDashApp: App {
    @StateObject private var scale = ScaleScanner()
    @StateObject private var ring = RingManager()
    @StateObject private var calories = CalorieModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(scale)
                .environmentObject(ring)
                .environmentObject(calories)
        }
        .modelContainer(for: [WeightReading.self, MetricSample.self, SleepSession.self, Profile.self])
    }
}
