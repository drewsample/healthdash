import SwiftUI
import SwiftData

struct DashboardView: View {
    @EnvironmentObject var scale: ScaleScanner
    @EnvironmentObject var ring: RingManager
    @Environment(\.modelContext) private var context

    @Query(sort: \WeightReading.timestamp, order: .reverse) private var weights: [WeightReading]
    @Query(sort: \MetricSample.timestamp, order: .reverse) private var samples: [MetricSample]
    @Query(sort: \SleepSession.start, order: .reverse) private var sleeps: [SleepSession]
    @Query private var profiles: [Profile]

    @State private var showSettings = false
    @State private var showRingPicker = false
    @State private var spotResult: String?

    private var profile: Profile { profiles.first ?? Profile() }
    private var latestWeight: WeightReading? { weights.first }
    private var weightKg: Double { latestWeight?.kg ?? 100 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    caloriesCard
                    weightCard
                    ringCard
                    sleepCard
                }
                .padding()
            }
            .navigationTitle("HealthDash")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showRingPicker) { RingPickerView() }
            .onAppear(perform: setup)
            .alert("Reading", isPresented: Binding(
                get: { spotResult != nil },
                set: { if !$0 { spotResult = nil } }
            )) { Button("OK", role: .cancel) {} } message: {
                Text(spotResult ?? "")
            }
        }
    }

    private func setup() {
        if profiles.isEmpty { context.insert(Profile()) }
        ring.attach(context)
        scale.attach(context)
        scale.start()
        Task { await HealthKitManager.shared.requestAuthorization() }
        ring.onSpotResult = { label, value in
            spotResult = String(format: "%@: %.0f", label, value)
        }
    }

    // MARK: - Calories

    private var caloriesCard: some View {
        let bmr = CalorieModel.bmr(profile: profile, weightKg: weightKg)
        let steps = CalorieModel.todaySteps(in: samples)
        let ringCal = CalorieModel.ringActiveCalories(on: Date(), in: samples)
        let active = CalorieModel.activeCalories(steps: steps, ringCalories: ringCal, weightKg: weightKg)
        let total = bmr + active
        let goal = Double(profile.calorieGoal)
        return Card(title: "Calories", subtitle: "estimate") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(total))")
                        .font(.system(size: 44, weight: .bold))
                    Text("of \(Int(goal)) kcal goal")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    metricRow("BMR", "\(Int(bmr))")
                    metricRow("Active", "\(Int(active))")
                    metricRow("Steps", "\(steps)")
                }
                .font(.subheadline)
            }
            ProgressView(value: min(total / goal, 1))
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Text(value).bold()
        }
    }

    // MARK: - Weight

    private var weightCard: some View {
        Card(title: "Weight", subtitle: scale.isScanning ? "listening…" : "scale idle") {
            if let w = latestWeight {
                let display = profile.usePounds ? w.kg * 2.20462 : w.kg
                let unit = profile.usePounds ? "lb" : "kg"
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.1f", display))
                        .font(.system(size: 44, weight: .bold))
                    Text(unit).foregroundStyle(.secondary)
                    Spacer()
                    if let imp = w.impedanceOhms {
                        Text(String(format: "%.0f Ω", imp))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("measured \(w.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                weightTrend
            } else if let live = scale.currentKg {
                let display = profile.usePounds ? live * 2.20462 : live
                Text(String(format: "%.1f %@", display, profile.usePounds ? "lb" : "kg"))
                    .font(.system(size: 44, weight: .bold))
                Text("step off the scale to lock it in")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Step on the scale — no app pairing needed, it broadcasts the reading.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var weightTrend: some View {
        let week = weights.filter { $0.timestamp > Date().addingTimeInterval(-7 * 86400) }
            .sorted { $0.timestamp < $1.timestamp }
        guard week.count >= 2 else { return AnyView(EmptyView()) }
        let vals = week.map(\.kg)
        let lo = vals.min()!, hi = vals.max()!
        let span = max(hi - lo, 0.5)
        return AnyView(
            GeometryReader { geo in
                Path { path in
                    for (i, v) in vals.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(vals.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(.blue, lineWidth: 2)
            }
            .frame(height: 60)
            .padding(.top, 8)
        )
    }

    // MARK: - Ring

    private var ringCard: some View {
        Card(title: "Ring", subtitle: ring.connectedName ?? "not connected") {
            if ring.connectedName == nil {
                Button("Connect ring") { showRingPicker = true }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    if let b = ring.battery {
                        Label("\(b)%", systemImage: "battery.75")
                    }
                    if let hr = ring.liveHeartRate {
                        Label("\(hr) bpm", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                    }
                    if let steps = ring.liveSteps {
                        Label("\(steps)", systemImage: "figure.walk")
                    }
                    Spacer()
                }
                .font(.subheadline)
                if !ring.syncDetail.isEmpty {
                    Text(ring.syncDetail).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(ring.state == .syncing ? "Syncing…" : "Sync now") { ring.syncNow() }
                        .buttonStyle(.bordered)
                        .disabled(ring.state != .ready)
                    Button("♥ Measure") { ring.measureHeartRate() }
                        .buttonStyle(.bordered)
                        .disabled(ring.state != .ready)
                    Button("O₂ Measure") { ring.measureSpo2() }
                        .buttonStyle(.bordered)
                        .disabled(ring.state != .ready)
                    Spacer()
                    Button("Disconnect", role: .destructive) { ring.disconnect() }
                        .font(.caption)
                }
                .font(.subheadline)
            }
            if let err = ring.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Sleep

    private var sleepCard: some View {
        Card(title: "Sleep", subtitle: "last night") {
            if let s = sleeps.first {
                let counts = s.minutesByStage
                let total = s.totalMinutes
                let h = total / 60, m = total % 60
                Text("\(h)h \(m)m").font(.system(size: 36, weight: .bold))
                sleepBar(counts: counts, total: total)
                HStack {
                    stageLegend("Deep", counts[1] ?? 0, .indigo)
                    stageLegend("Light", counts[2] ?? 0, .blue)
                    stageLegend("REM", counts[3] ?? 0, .purple)
                    stageLegend("Awake", counts[4] ?? 0, .orange)
                }
                .font(.caption)
                Text("in bed \(s.start.formatted(date: .omitted, time: .shortened)) → \(s.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(ring.connectedName == nil
                     ? "Sleep appears here after you connect the ring and sync."
                     : "No sleep synced yet — wear the ring overnight, then sync.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func sleepBar(counts: [Int: Int], total: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach([1, 2, 3, 4], id: \.self) { stage in
                    let frac = total > 0 ? CGFloat(counts[stage] ?? 0) / CGFloat(total) : 0
                    Rectangle()
                        .fill(stageColor(stage))
                        .frame(width: geo.size.width * frac)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 10)
    }

    private func stageColor(_ stage: Int) -> Color {
        switch stage { case 1: return .indigo; case 2: return .blue; case 3: return .purple; default: return .orange }
    }

    private func stageLegend(_ label: String, _ minutes: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(minutes)m")
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Ring picker

struct RingPickerView: View {
    @EnvironmentObject var ring: RingManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if ring.discovered.isEmpty {
                    Text("Scanning… make sure the ring is charged and nearby.")
                        .foregroundStyle(.secondary)
                }
                ForEach(ring.discovered) { d in
                    Button {
                        ring.connect(d)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name).bold()
                                Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if d.looksLikeRing {
                                Text("TK5").font(.caption).bold()
                                    .padding(6)
                                    .background(.green.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose ring")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Scan") { ring.startScan() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { ring.startScan() }
            .onDisappear { ring.stopScan() }
        }
    }
}
