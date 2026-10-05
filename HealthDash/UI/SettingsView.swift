import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [Profile]

    var body: some View {
        NavigationStack {
            if let p = profiles.first {
                Form {
                    Section("Profile") {
                        Stepper("Age: \(p.age)", value: Binding(
                            get: { p.age }, set: { p.age = $0 }), in: 10...100)
                        Toggle("Male", isOn: Binding(
                            get: { p.isMale }, set: { p.isMale = $0 }))
                        HStack {
                            Text("Height")
                            Spacer()
                            TextField("cm", value: Binding(
                                get: { p.heightCm }, set: { p.heightCm = $0 }),
                                format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("cm")
                        }
                    }
                    Section("Goals & units") {
                        Stepper("Calorie goal: \(p.calorieGoal) kcal", value: Binding(
                            get: { p.calorieGoal }, set: { p.calorieGoal = $0 }),
                            in: 1200...5000, step: 50)
                        Toggle("Use pounds", isOn: Binding(
                            get: { p.usePounds }, set: { p.usePounds = $0 }))
                    }
                    Section("About") {
                        Text("HealthDash reads your OKOK scale and TK5 ring over Bluetooth and writes weight, steps, heart rate, SpO2, HRV, and sleep to Apple Health. Everything stays on this phone — no accounts, no cloud, no ads.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Calorie totals are estimates, not measurements.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Data") {
                        Button("Delete all history", role: .destructive) {
                            deleteAll()
                        }
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            } else {
                Text("Loading…").onAppear {
                    if profiles.isEmpty { context.insert(Profile()) }
                }
            }
        }
    }

    private func deleteAll() {
        try? context.delete(model: WeightReading.self)
        try? context.delete(model: MetricSample.self)
        try? context.delete(model: SleepSession.self)
        try? context.save()
    }
}
