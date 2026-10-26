import Charts
import SwiftUI

/// Fitness: a strip of days with what you did on each, how ready you are to train, a word on
/// what that means, and the day's workouts.
struct FitnessView: View {
    @EnvironmentObject private var store: HealthStore
    @Binding var showSettings: Bool

    var body: some View {
        let day = store.selectedDay
        NavigationStack {
            HaloPage(showSettings: $showSettings, title: "Fitness") {
                DayStrip()
                ReadinessCard()
                ActivitiesSection()
                CardioLoadCard()
                if !day.heartRate.isEmpty { HeartZonesCard(day: day) }
            }
            .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
            .navigationDestination(for: ZonesRoute.self) { HeartZonesView(date: $0.date) }
            .navigationDestination(for: WorkoutRoute.self) { WorkoutView(route: $0) }
        }
    }
}

// MARK: - Days

/// A row of days, like a training log: each shows the main thing you did, or a rest day.
struct DayStrip: View {
    @EnvironmentObject private var store: HealthStore
    private let pastDays = 27, futureDays = 3

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let dates = (-pastDays...futureDays).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(dates, id: \.self) { d in
                        pill(d, today: today).id(d)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, -20)   // run edge to edge
            .onAppear { proxy.scrollTo(store.selectedDate, anchor: .center) }
            .onChange(of: store.selectedDate) { _, d in withAnimation(.snappy) { proxy.scrollTo(d, anchor: .center) } }
        }
    }

    /// A date, and under it one accent dot per workout (up to three), or a faint ring on a rest day.
    private func pill(_ d: Date, today: Date) -> some View {
        let cal = Calendar.current
        let isFuture = d > today
        let isToday = cal.isDate(d, inSameDayAs: today)
        let isSelected = cal.isDate(d, inSameDayAs: store.selectedDate)
        let count = isFuture ? 0 : store.activities(on: d).count
        return Button { store.select(d) } label: {
            VStack(spacing: 7) {
                Text(d.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                Text("\(cal.component(.day, from: d))")
                    .font(Theme.number(17, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.background : Theme.ink)
                    .frame(width: 38, height: 38)
                    .background {
                        if isSelected { Circle().fill(Theme.ink) }
                        else if isToday { Circle().stroke(Theme.accent, lineWidth: 1.5) }
                    }
                HStack(spacing: 3) {
                    if count > 0 {
                        ForEach(0..<min(count, 3), id: \.self) { _ in
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        }
                    } else if !isFuture {
                        Circle().stroke(Theme.ink.opacity(0.25), lineWidth: 1).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(width: 44)
        }
        .buttonStyle(.plain)
        .disabled(isFuture || store.day(d) == nil)
        .opacity(isFuture ? 0.35 : 1)
        .accessibilityLabel("\(d.formatted(date: .complete, time: .omitted)), \(count == 0 ? "rest day" : "\(count) workouts")")
    }
}

// MARK: - Readiness

/// One thin line of even segments: the more are lit, the readier you are to train.
struct ReadinessMeter: View {
    let value: Double
    var segments = 40

    var body: some View {
        GeometryReader { g in
            let lit = Int((value * Double(segments)).rounded())
            let gap: CGFloat = 2
            let w = (g.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i < lit ? (i == lit - 1 ? Theme.accent : Theme.ink.opacity(0.75)) : Theme.track)
                        .frame(width: w)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Readiness \(Int((value * 100).rounded())) out of 100")
    }
}

struct ReadinessCard: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let r = store.readiness(for: store.selectedDate)
        let words = Self.words(r)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Readiness").haloLabel()
                Spacer()
                Text(r.map { "\(Int(($0 * 100).rounded()))" } ?? "–").font(Theme.number(30)).foregroundStyle(Theme.ink)
                Text("/ 100").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            ReadinessMeter(value: r ?? 0).frame(height: 10)
                .animation(.smooth(duration: 0.6), value: r)
            HStack {
                Text("Take a day off")
                Spacer()
                Text("Go hard")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text(words.title).font(Theme.number(22)).foregroundStyle(Theme.ink)
                Text(words.line).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .haloCard()
    }

    static func words(_ r: Double?) -> (title: String, line: String) {
        guard let r else { return ("Waiting for last night", "Wear your Fitbit to sleep and Halo will tell you how ready you are.") }
        switch r {
        case 0.8...: return ("Go break something", "Everything's in your favour. Push the pace, go long or lift heavy.")
        case 0.6..<0.8: return ("Ready for exercise", "Train as planned. Save the all-out efforts for a fresher day.")
        case 0.4..<0.6: return ("Keep it light", "A walk, an easy spin or some mobility will do more good than a hard session.")
        default: return ("Take a day off", "Your body is still catching up. Rest, eat well and get to bed early.")
        }
    }
}

// MARK: - Activities

struct WorkoutRoute: Hashable {
    let id: String
    let date: Date
}

struct ActivitiesSection: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        let workouts = store.activities(on: store.selectedDate)
        let examples = workouts.contains(where: \.isExample)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.isTodaySelected ? "Today's activities" : "Activities").haloLabel()
                Spacer()
                if !workouts.isEmpty {
                    Text("\(workouts.count) · \(Format.duration(workouts.reduce(0) { $0 + $1.minutes }))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 4)
            if workouts.isEmpty {
                HStack(spacing: 14) {
                    Text("z z").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.tertiary)
                        .frame(width: 44, height: 44)
                        .overlay(Circle().stroke(Theme.hairline))
                    Text("Rest day").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
            ForEach(workouts) { w in
                NavigationLink(value: WorkoutRoute(id: w.id, date: store.selectedDate)) { WorkoutRow(workout: w) }
                    .buttonStyle(.plain)
            }
            if examples {
                Text("These two are examples. Workouts your Fitbit logs show up here; tap one to change its type.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct WorkoutRow: View {
    @EnvironmentObject private var store: HealthStore
    let workout: Workout

    var body: some View {
        let type = store.activityType(workout)
        HStack(spacing: 14) {
            Image(systemName: type.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 46, height: 46)
                .background(Theme.accent.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(type.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    Text("\(Format.time(workout.start)) – \(Format.time(workout.end))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if workout.isExample {
                        Text("EXAMPLE").font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                }
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.duration(workout.minutes)).font(Theme.number(17, weight: .semibold)).foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    if let c = workout.calories { Text("\(Int(c)) kcal") }
                    if let hr = workout.averageHeartRate { Text("\(Int(hr)) bpm") }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                .lineLimit(1)
            }
            .fixedSize()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
        }
        .haloCard(padding: 14)
    }
}

// MARK: - One workout

struct WorkoutView: View {
    @EnvironmentObject private var store: HealthStore
    @Environment(\.openSettings) private var openSettings
    let route: WorkoutRoute
    @State private var picking = false

    var body: some View {
        let w = store.activities(on: route.date).first { $0.id == route.id }
        ScrollView {
            if let w { content(w) } else {
                Text("This workout isn't here any more.").font(.system(size: 15)).foregroundStyle(Theme.secondary).padding(40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(w.map { store.activityType($0).title } ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $picking) {
            if let w {
                ActivityPicker(selected: store.activityType(w)) { type in
                    store.setActivityType(type, for: w)
                    picking = false
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func content(_ w: Workout) -> some View {
        let type = store.activityType(w)
        let day = store.day(route.date) ?? DayMetrics(date: route.date)
        let scale = store.zoneScale(for: day)
        let samples = day.heartRate.filter { $0.time >= w.start && $0.time <= w.end }
        let zoneMinutes = Self.zoneMinutes(samples, scale: scale)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: type.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(type.title).font(Theme.number(26)).foregroundStyle(Theme.ink)
                    Text("\(Format.dayTitle(w.start)) · \(Format.time(w.start)) – \(Format.time(w.end))")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .padding(.top, 8)

            Button { picking = true } label: {
                Label("Change type", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.card, in: Capsule())
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                stat("Duration", Format.duration(w.minutes))
                stat("Calories", w.calories.map { "\(Int($0)) kcal" } ?? "–")
                stat("Average heart rate", w.averageHeartRate.map { "\(Int($0)) bpm" } ?? "–")
                stat(w.distanceKm == nil ? "Peak heart rate" : "Distance",
                     w.distanceKm.map { String(format: "%.1f km", $0) } ?? (samples.map(\.bpm).max().map { "\(Int($0)) bpm" } ?? "–"))
            }

            if samples.count >= 2 {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Heart rate").haloLabel()
                    Chart {
                        ForEach(HeartZone.allCases) { z in
                            RuleMark(y: .value("Zone", scale.bpm(z)))
                                .foregroundStyle(z.color.opacity(0.8))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                        ForEach(samples, id: \.time) { s in
                            LineMark(x: .value("Time", s.time), y: .value("BPM", s.bpm))
                                .foregroundStyle(Theme.ink)
                                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: max(40, (samples.map(\.bpm).min() ?? 60) - 10)...max(scale.bpm(.peak), (samples.map(\.bpm).max() ?? 120)) + 6)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel().foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(height: 170)
                    ZoneBars(minutes: zoneMinutes, scale: scale, selected: nil)
                }
                .haloCard()
            } else {
                Text(w.isExample ? "This is an example workout. Real ones show your heart rate through the session and the time in each zone."
                                 : "Heart rate for this workout isn't on your phone. Halo keeps it for the last two weeks.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .haloCard()
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).haloLabel()
            Text(value).font(Theme.number(20)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .haloCard(padding: 14)
    }

    static func zoneMinutes(_ samples: [HeartSample], scale: ZoneScale) -> ZoneMinutes {
        var z = ZoneMinutes()
        for (i, s) in samples.enumerated() {
            let next = i + 1 < samples.count ? samples[i + 1].time : s.time.addingTimeInterval(300)
            let minutes = min(next.timeIntervalSince(s.time), 300) / 60
            switch scale.zone(s.bpm) {
            case .fatBurn: z.fatBurn += minutes
            case .cardio: z.cardio += minutes
            case .peak: z.peak += minutes
            case nil: break
            }
        }
        return z
    }
}

/// Every workout type, as a grid of symbols.
struct ActivityPicker: View {
    let selected: ActivityType
    let onPick: (ActivityType) -> Void
    @State private var search = ""

    var body: some View {
        let types = ActivityType.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                    ForEach(types) { t in
                        Button { onPick(t) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: t.symbol)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(t == selected ? Theme.background : Theme.ink)
                                    .frame(width: 54, height: 54)
                                    .background(t == selected ? Theme.accent : Theme.card, in: Circle())
                                Text(t.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.center).lineLimit(2)
                                    .frame(height: 28, alignment: .top)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .searchable(text: $search, prompt: "Search activities")
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Activity type")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.ink)
    }
}
