import Charts
import SwiftUI

/// Testing only: Fitbit, Whoop and Apple Watch side by side for one day, Halo's three scores from
/// each band's data (and Whoop's own), the main numbers, the heart rate over the day, and a copy
/// button for everything. Fitbit still runs the rings; this tab goes once testing is done.
struct CompareView: View {
    @EnvironmentObject private var store: HealthStore
    @EnvironmentObject private var compare: CompareStore
    @State private var date = Calendar.current.startOfDay(for: .now)
    @State private var error: String?
    @State private var copied = false

    private let devices = CompareStore.Device.allCases

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    bands
                    scores
                    numbers
                    heart
                    copyCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await compare.syncAll(main: store) }
            .task { if compare.lastSync == nil { await compare.syncAll(main: store) } }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink).padding(.top, 12)
            Text("Testing: three bands worn together. Fitbit runs the rings; this tab goes once testing is done.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36).background(Theme.card, in: Circle()) }
                Spacer()
                Text(Format.dayTitle(date)).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36).background(Theme.card, in: Circle()) }
                    .disabled(Calendar.current.isDateInToday(date))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
        }
    }

    private var bands: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bands").haloLabel()
                Spacer()
                Button {
                    Task { await compare.syncAll(main: store) }
                } label: {
                    HStack(spacing: 6) {
                        if !compare.syncing.isEmpty { ProgressView().controlSize(.mini) }
                        Text(compare.syncing.isEmpty ? "Sync all" : "Syncing").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Theme.track, in: Capsule())
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(!compare.syncing.isEmpty)
            }
            ForEach(devices) { d in
                HStack {
                    Circle().fill(color(d)).frame(width: 8, height: 8)
                    Text(d.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                    if d == .fitbit { Text("main").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary) }
                    Spacer()
                    if compare.syncing.contains(d) {
                        ProgressView().controlSize(.small)
                    } else if compare.isConnected(d) {
                        Text(compare.errors[d].map { "Error: \($0)" } ?? "\(compare.days[d]?.count ?? 0) days")
                            .font(.system(size: 12)).foregroundStyle(compare.errors[d] == nil ? Theme.secondary : Theme.accent)
                            .lineLimit(2).multilineTextAlignment(.trailing)
                    } else {
                        Button("Connect") {
                            Task {
                                do { try await compare.connect(d); await compare.syncAll(main: store) } catch { self.error = error.localizedDescription }
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Theme.ink, in: Capsule())
                        .foregroundStyle(Theme.background)
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 30)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            Text("Apple Watch counts only what the watch recorded. Whoop's heart rate comes from Apple Health (turn on Apple Health in the Whoop app under Settings › Integrations).")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .haloCard()
    }

    private var scores: some View {
        let s = Dictionary(uniqueKeysWithValues: devices.map { ($0, compare.haloScores($0, date, targets: store.targets)) })
        let whoop = compare.day(.whoop, date)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Halo's scores from each band").haloLabel()
            grid(rows: [
                ("Recovery", devices.map { pct(s[$0]??.recovery) }),
                ("Sleep", devices.map { pct(s[$0]??.sleep) }),
                ("Effort", devices.map { pct(s[$0]??.effort) }),
            ], big: true)
            if whoop?.bandRecovery != nil || whoop?.bandSleepScore != nil {
                Text("Whoop's own: recovery \(pct(whoop?.bandRecovery)) · sleep \(pct(whoop?.bandSleepScore))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .haloCard()
    }

    private var numbers: some View {
        let x = Dictionary(uniqueKeysWithValues: devices.map { ($0, compare.day($0, date)) })
        func row(_ name: String, _ f: (DayMetrics) -> String) -> (String, [String]) {
            (name, devices.map { d in x[d].flatMap { $0 }.map(f) ?? "–" })
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("The numbers").haloLabel()
            grid(rows: [
                row("Asleep") { $0.sleep.map { Format.duration($0.minutesAsleep) } ?? "–" },
                row("Bed") { $0.sleep.map { "\(Format.time($0.start))–\(Format.time($0.end))" } ?? "–" },
                row("Deep · REM") { $0.sleep.map { "\(Int($0.minutes(.deep))) · \(Int($0.minutes(.rem)))" } ?? "–" },
                row("HRV ms") { n($0.hrv) },
                row("Resting HR") { n($0.restingHeartRate) },
                row("Breathing") { n($0.respiratoryRate, 1) },
                row("SpO₂ %") { n($0.spo2, 1) },
                row("Steps") { $0.steps.map { $0.formatted() } ?? "–" },
                row("Active kcal") { n($0.activeCalories) },
                row("Cardio load") { n($0.cardioLoad) },
                row("Active min") { $0.zones.map { "\(Int($0.fatBurn + 2 * ($0.cardio + $0.peak)))" } ?? "–" },
            ], big: false)
            Text("HRV: Apple Watch measures SDNN, Fitbit and Whoop RMSSD, so the watch's runs on another scale.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .haloCard()
    }

    private var heart: some View {
        let series = devices.flatMap { d in (compare.day(d, date)?.heartRate ?? []).map { (d, $0) } }
        let start = Calendar.current.startOfDay(for: date)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Heart rate over the day").haloLabel()
            if series.isEmpty {
                Text("No heart rate for this day yet.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            } else {
                Chart {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Time", p.1.time), y: .value("BPM", p.1.bpm), series: .value("Band", p.0.title))
                            .foregroundStyle(by: .value("Band", p.0.title))
                            .lineStyle(StrokeStyle(lineWidth: 1.3))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartForegroundStyleScale(domain: devices.map(\.title), range: devices.map(color))
                .chartXScale(domain: start...start.addingTimeInterval(86_400))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.tertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel().foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(height: 200)
            }
        }
        .haloCard()
    }

    private var copyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                UIPasteboard.general.string = compare.text(days: 14, targets: store.targets, maxHeartRate: store.profile.maxHeartRate)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy all data (last 14 days)", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Theme.background)
            }
            .buttonStyle(.plain)
            Text("Every day's scores and numbers from all three bands, and what each last sync found, as text to paste into a message.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .haloCard()
    }

    // MARK: Helpers

    private func grid(rows: [(String, [String])], big: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("")
                ForEach(devices) { d in
                    Text(d.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color(d))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                GridRow {
                    Text(r.0).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    ForEach(Array(r.1.enumerated()), id: \.offset) { _, v in
                        Text(v).font(Theme.number(big ? 20 : 14, weight: big ? .semibold : .medium)).foregroundStyle(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func color(_ d: CompareStore.Device) -> Color {
        switch d {
        case .fitbit: return Theme.ink
        case .whoop: return Theme.accent
        case .watch: return Color(red: 0.35, green: 0.62, blue: 1.0)
        }
    }

    private func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))" } ?? "–" }
    private func n(_ v: Double?, _ digits: Int = 0) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }

    private func step(_ delta: Int) {
        guard let d = Calendar.current.date(byAdding: .day, value: delta, to: date) else { return }
        date = min(Calendar.current.startOfDay(for: .now), d)
    }
}
