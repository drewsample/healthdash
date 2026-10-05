import SwiftUI
import SwiftData

@main
struct HealthDashApp: App {
    @StateObject private var scale = ScaleScanner()
    @StateObject private var ring = RingManager()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(scale)
                .environmentObject(ring)
        }
        .modelContainer(for: [WeightReading.self, MetricSample.self, SleepSession.self, Profile.self])
    }
}
