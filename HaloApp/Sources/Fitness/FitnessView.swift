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
                DayStrip().spansColumns()
                ReadinessCard()
                ActivitiesSection()
                FitnessInsightsCard().plusLocked(reason: "Your fitness insights are part of Halo Plus.")
                if store.hasZoneChart(day) { HeartZonesCard(day: day) }
                CardioLoadCard().plusLocked()
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
    @Environment(\.wideLayout) private var wide
    @State private var stripWidth: CGFloat = 0
    private let pastDays = 27, futureDays = 3

    var body: some View {
        if wide { spread } else { scrolling }
    }

    /// On a wide screen: as many whole days as fit, spread evenly, never one cut off at an edge.
    private var spread: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let count = max(7, Int(stripWidth / 54))
        let latest = cal.date(byAdding: .day, value: futureDays, to: today) ?? today
        // the chosen day stays in view, a couple of days in from the right if it's further back
        let back = cal.dateComponents([.day], from: store.selectedDate, to: latest).day ?? 0
        let end = back >= count - 1 ? (cal.date(byAdding: .day, value: 2, to: store.selectedDate) ?? latest) : latest
        let dates = (0..<count).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: end) }
        return HStack(spacing: 0) {
            ForEach(dates, id: \.self) { d in
                pill(d, today: today).frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
        .animation(.snappy, value: end)
    }

    @ViewBuilder private var scrolling: some View {
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
        let words = r == nil && store.isSyncing && store.isTodaySelected
            ? (title: "Updating", line: "Getting today's data from your band.")
            : Self.words(r, on: store.selectedDate)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Readiness").haloLabel()
                Spacer()
                Text(r.map { "\(Int(($0 * 100).rounded()))" } ?? "–").font(Theme.number(30)).foregroundStyle(Theme.text)
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
                Text(words.title).font(Theme.number(22)).foregroundStyle(Theme.text)
                Text(words.line).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .haloCard()
    }

    /// What the readiness means, in one of ten ways per level: the same day always reads the
    /// same, and the next day at the same level reads differently.
    static func words(_ r: Double?, on date: Date = .now) -> (title: String, line: String) {
        guard let r else { return ("Waiting for last night", "Wear your band to sleep and Halo will tell you how ready you are.") }
        let set: [(String, String)]
        switch r {
        case 0.8...: set = peak
        case 0.6..<0.8: set = ready
        case 0.4..<0.6: set = easy
        default: set = rest
        }
        let day = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970 / 86_400)
        // 7 shares nothing with 10, so neighbouring days never land on the same line
        let i = ((day * 7) % set.count + set.count) % set.count
        return set[i]
    }

    private static let peak: [(String, String)] = [
        ("Go break something", "Everything's in your favour. Push the pace, go long or lift heavy."),
        ("Green light", "Your body's fully charged. Today's the day for the session you've been putting off."),
        ("Fully loaded", "Recovered, rested and ready. Chase a personal best."),
        ("Big day energy", "Your numbers are as good as they get. Make the hard workout count."),
        ("Primed", "Heart, sleep and recovery all line up. Go for intervals, hills or heavy sets."),
        ("All systems go", "No reason to hold back. Go further or faster than usual."),
        ("Peak form", "This is what well rested looks like. Spend it on something tough."),
        ("Let it rip", "Your recovery has your back today. Race it, climb it, lift it."),
        ("Ready to roar", "Plenty in the tank. Try the effort you'd skip on a tired day."),
        ("On fire", "A rare top-score day. Don't waste it on the sofa."),
    ]

    private static let ready: [(String, String)] = [
        ("Ready for exercise", "Train as planned. Save the all-out efforts for a fresher day."),
        ("Good to go", "Solid recovery. A normal training day suits you well."),
        ("Steady and strong", "Your body can take a proper workout. Keep the hardest efforts short."),
        ("In good shape", "Go for your usual session, and listen in if the legs feel heavy."),
        ("Ready to roll", "Enough in the tank for real work. Just don't empty it."),
        ("Game on", "A good day for a moderate run, ride or gym session."),
        ("Solid footing", "Recovered well. Build on it with a steady, honest effort."),
        ("Warmed up", "Your numbers say yes to training. Keep one gear in reserve."),
        ("Cleared for takeoff", "Train with intent today, finish feeling you could do a little more."),
        ("Nicely charged", "Good recovery. Tempo work or a strong steady session fits."),
    ]

    private static let easy: [(String, String)] = [
        ("Keep it light", "A walk, an easy spin or some mobility will do more good than a hard session."),
        ("Easy does it", "Your body's half way there. Move, but keep it conversational."),
        ("Cruise control", "Nothing hard today. An easy pace now means a better session tomorrow."),
        ("Gentle day", "Stretch, walk or do some yoga. Let recovery catch up."),
        ("Ease off", "Not a day for records. Light movement helps more than pushing."),
        ("Take it slow", "A relaxed session is fine. If it starts to hurt, call it."),
        ("Half charge", "Enough for a stroll or a light ride, not for intervals."),
        ("Recharge mode", "Keep your heart rate low today and you'll bounce back faster."),
        ("Low gear", "Easy movement, more water and an early night will pay off."),
        ("Steady, not heavy", "Skip the hard stuff. Technique, mobility or a long walk fit nicely."),
    ]

    private static let rest: [(String, String)] = [
        ("Take a day off", "Your body is still catching up. Rest, eat well and get to bed early."),
        ("Rest day", "Recovery is training too. Today, let your body rebuild."),
        ("Recharge", "Running low. Put your feet up and give tonight's sleep a head start."),
        ("Hit pause", "Your numbers ask for a break. Tomorrow will thank you."),
        ("Battery low", "Skip the workout and focus on food, water and sleep."),
        ("Sofa approved", "A rest day now beats an injury later."),
        ("Recover first", "Your body's working hard behind the scenes. Let it."),
        ("Slow it down", "A short walk at most. The rest is up to sleep."),
        ("Off duty", "No training today. Fill up on rest and you'll come back stronger."),
        ("Refuel", "Eat well, drink plenty and get to bed early tonight."),
    ]
}

// MARK: - Activities

struct WorkoutRoute: Hashable {
    let id: String
    let date: Date
}

struct ActivitiesSection: View {
    @EnvironmentObject private var store: HealthStore
    @State private var adding = false

    var body: some View {
        let workouts = store.activities(on: store.selectedDate)
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
                    Text(store.isTodaySelected ? "No activities yet today" : "Rest day").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
            ForEach(workouts) { w in
                NavigationLink(value: WorkoutRoute(id: w.id, date: store.selectedDate)) { WorkoutRow(workout: w) }
                    .buttonStyle(.plain)
            }
            // one the band missed, at the time it happened
            Button { adding = true } label: {
                Label("Add an activity", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.card, in: Capsule())
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $adding) {
            AddActivitySheet(day: store.selectedDate)
                .presentationDetents([.medium, .large])
        }
    }
}

/// Adds an activity by hand: what, when it started, how long, and the calories if you know them.
struct AddActivitySheet: View {
    @EnvironmentObject private var store: HealthStore
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var type = ActivityType.walking
    @State private var start = Date.now
    @State private var minutes = 30.0
    @State private var calories = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Activity", selection: $type) {
                        ForEach(ActivityType.allCases) { t in
                            Label(t.title, systemImage: t.symbol).tag(t)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    DatePicker("Started", selection: $start, in: dayRange, displayedComponents: .hourAndMinute)
                    Stepper(value: $minutes, in: 5...600, step: 5) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(Format.duration(minutes)).foregroundStyle(Theme.secondary)
                        }
                    }
                    HStack {
                        Text("Calories")
                        Spacer()
                        TextField("Optional", text: $calories)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                } footer: {
                    Text("For an activity your band didn't pick up. It shows in your activities for \(Format.dayTitle(day).lowercased()).")
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Add an activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.addWorkout(type, start: start, minutes: minutes, calories: Double(calories))
                        dismiss()
                    }
                }
            }
            .onAppear {
                // a time on the day shown: now for today, midday for an earlier day
                let cal = Calendar.current
                if !cal.isDateInToday(day) {
                    start = cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
                }
            }
        }
    }

    /// Times on the day being added to, up to now.
    private var dayRange: ClosedRange<Date> {
        let cal = Calendar.current
        let from = cal.startOfDay(for: day)
        let to = min(Date.now, from.addingTimeInterval(86_399))
        return from...max(from, to)
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
                Text(type.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    Text("\(Format.time(workout.start)) – \(Format.time(workout.end))")
                    if workout.isExample {
                        Text("EXAMPLE").font(.system(size: 8, weight: .bold)).tracking(0.6).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .lineLimit(1)
                HStack(spacing: 8) {
                    if let c = workout.calories { Text("\(Int(c)) kcal") }
                    if let hr = workout.averageHeartRate { Text("\(Int(hr)) bpm avg") }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Format.duration(workout.minutes)).font(Theme.number(18, weight: .semibold)).foregroundStyle(Theme.text)
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
    @Environment(\.dismiss) private var dismiss

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
                    Text(type.title).font(Theme.number(26)).foregroundStyle(Theme.text)
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
            if w.isManual {
                Button(role: .destructive) {
                    store.removeWorkout(w)
                    dismiss()
                } label: {
                    Label("Remove this activity", systemImage: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Theme.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                stat("Duration", Format.duration(w.minutes))
                stat("Calories", w.calories.map { "\(Int($0)) kcal" } ?? "–")
                stat("Average heart rate", w.averageHeartRate.map { "\(Int($0)) bpm" } ?? "–")
                stat(w.distanceKm == nil ? "Started" : "Distance",
                     w.distanceKm.map { String(format: "%.1f km", $0) } ?? Format.time(w.start))
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

            // more numbers, the band's zones, and what it meant against the rest of your data
            WorkoutDeepDive(workout: w, samples: samples)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 32)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).haloLabel()
            Text(value).font(Theme.number(20)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
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
                                Text(t.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
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
