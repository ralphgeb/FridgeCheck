import Foundation
import HealthKit

/// Reads Apple Health (HealthKit) on this iPhone: everything an Apple Watch records, and whatever
/// other apps (Garmin, Oura, Google Health…) write there.
///
/// Apple Watch measures HRV as SDNN, where Fitbit and most bands use RMSSD, so the two don't compare:
/// switching sources starts your baselines again.
struct HealthKitClient: HealthSource {
    static let store = HKHealthStore()
    private static let connectedKey = "appleHealth.connected"

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// True once you've been through Apple's permission sheet. Apple never says which types you
    /// allowed (only that you were asked), so missing ones show up as "No data" in the sync report.
    static var isConnected: Bool { isAvailable && UserDefaults.standard.bool(forKey: connectedKey) }

    static func connect() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
        UserDefaults.standard.set(true, forKey: connectedKey)
    }

    /// Stops reading. Access itself can only be removed in the Health app (Apple doesn't let apps do it).
    static func disconnect() { UserDefaults.standard.set(false, forKey: connectedKey) }

    /// Wakes Halo when new heart rate, steps, workouts or sleep land in Apple Health (as often as
    /// iOS allows: heart rate and steps about hourly at most, workouts and sleep soon after), and
    /// syncs. Only the new readings are fetched, so it's quick.
    static func startBackgroundDelivery(sync: @escaping @MainActor () async -> Void) {
        let types: [HKSampleType] = [HKQuantityType(.heartRate), HKQuantityType(.stepCount),
                                     HKObjectType.workoutType(), HKCategoryType(.sleepAnalysis),
                                     HKQuantityType(.heartRateVariabilitySDNN)]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    await sync()
                    completion()
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate), HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.respiratoryRate), HKQuantityType(.oxygenSaturation),
        HKQuantityType(.appleSleepingWristTemperature), HKQuantityType(.bodyTemperature),
        HKQuantityType(.vo2Max), HKQuantityType(.bodyMass),
        HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming),
        HKCategoryType(.sleepAnalysis), HKObjectType.workoutType(),
    ]

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    func fetchDays(_ count: Int, maxHeartRate: Double) async throws -> (days: [DayMetrics], report: [SyncReportLine]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let from = cal.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        let end = cal.date(byAdding: .day, value: 1, to: today) ?? .now
        var days: [Date: DayMetrics] = [:]
        var report: [SyncReportLine] = []
        func edit(_ date: Date, _ change: (inout DayMetrics) -> Void) {
            let key = cal.startOfDay(for: date)
            guard key >= from else { return }
            var d = days[key] ?? DayMetrics(date: key)
            change(&d)
            days[key] = d
        }
        func take<T>(_ name: String, _ result: Result<[T], Error>, unit: String = "days") -> [T] {
            Self.take(name, result, unit: unit, into: &report)
        }

        // Everything runs at once. Totals come from Apple's statistics, which don't double count
        // when both the iPhone and a watch recorded the same steps.
        async let steps = attempt { try await daily(.stepCount, unit: .count(), sum: true, from: from, to: end) }
        let twoWeeks = cal.date(byAdding: .day, value: -13, to: today) ?? today
        async let hourSteps = attempt { try await daily(.stepCount, unit: .count(), sum: true, from: twoWeeks, to: end, every: DateComponents(hour: 1)) }
        async let hourKcal = attempt { try await daily(.activeEnergyBurned, unit: .kilocalorie(), sum: true, from: twoWeeks, to: end, every: DateComponents(hour: 1)) }
        async let kcal = attempt { try await daily(.activeEnergyBurned, unit: .kilocalorie(), sum: true, from: from, to: end) }
        async let rhr = attempt { try await daily(.restingHeartRate, unit: Self.bpm, sum: false, from: from, to: end) }
        async let resp = attempt { try await daily(.respiratoryRate, unit: Self.bpm, sum: false, from: from, to: end) }
        async let spo2 = attempt { try await daily(.oxygenSaturation, unit: .percent(), sum: false, from: from, to: end) }
        async let vo2 = attempt { try await daily(.vo2Max, unit: HKUnit(from: "ml/kg*min"), sum: false, from: from, to: end) }
        async let hrv = attempt { try await samples(.heartRateVariabilitySDNN, from: from) }
        async let wrist = attempt { try await samples(.appleSleepingWristTemperature, from: from) }
        async let body = attempt { try await samples(.bodyTemperature, from: from) }
        async let weights = attempt { try await samples(.bodyMass, from: from) }
        async let sleeps = attempt { try await sleepSessions(from: from) }
        async let exercises = attempt { try await workouts(from: cal.date(byAdding: .day, value: -60, to: today) ?? from) }
        // Heart rate is on the phone, so Halo can read five weeks of it: enough for the weekly cardio
        // target, which looks back four weeks.
        async let heart = attempt { try await samples(.heartRate, from: cal.date(byAdding: .day, value: -35, to: today) ?? from) }

        for (date, v) in take("Steps", await steps) { edit(date) { $0.steps = Int(v.rounded()) } }
        for (date, v) in take("Active calories", await kcal) { edit(date) { $0.activeCalories = v } }
        for (date, v) in take("Resting heart rate", await rhr) { edit(date) { $0.restingHeartRate = v } }
        for (date, v) in take("Breathing rate", await resp) { edit(date) { $0.respiratoryRate = v } }
        for (date, v) in take("Blood oxygen", await spo2) { edit(date) { $0.spo2 = v * 100 } }
        for (date, v) in take("Cardio fitness", await vo2) { edit(date) { $0.vo2Max = v } }
        let weightSamples = take("Weight", await weights, unit: "readings")
        for s in weightSamples { edit(s.endDate) { $0.weightKg = s.quantity.doubleValue(for: .gramUnit(with: .kilo)) } }

        // Sleep belongs to the day you woke up on. If there are several (naps), keep the longest.
        let sleepResult = await sleeps
        for s in take("Sleep", sleepResult, unit: "nights") {
            edit(s.end) { d in
                if (d.sleep?.minutesAsleep ?? 0) < s.minutesAsleep { d.sleep = s }
            }
        }

        // HRV: Apple Watch takes readings through the day and night. Halo uses the ones taken while
        // you slept (like Fitbit and Whoop), and the day's average when there were none.
        let hrvSamples = take("HRV", await hrv, unit: "readings")
        for (day, group) in Dictionary(grouping: hrvSamples, by: { cal.startOfDay(for: $0.endDate) }) {
            let values = { (list: [HKQuantitySample]) in list.map { $0.quantity.doubleValue(for: .secondUnit(with: .milli)) } }
            edit(day) { d in
                let asleep = d.sleep.map { s in group.filter { $0.startDate >= s.start && $0.endDate <= s.end } } ?? []
                d.hrv = ScoreEngine.mean(values(asleep.isEmpty ? group : asleep))
            }
        }

        // Temperature: Apple Watch records your wrist temperature each night. Halo shows the change
        // from your previous 30 nights, as Fitbit does. Without a watch, other apps' body temperature.
        var temps = take("Skin temperature", await wrist, unit: "nights")
        if temps.isEmpty { temps = take("Body temperature", await body, unit: "readings") }
        let nightly = Dictionary(grouping: temps, by: { cal.startOfDay(for: $0.endDate) })
            .compactMap { day, list in ScoreEngine.mean(list.map { $0.quantity.doubleValue(for: .degreeCelsius()) }).map { (day, $0) } }
        for (day, delta) in Self.changeFromUsual(nightly) { edit(day) { $0.skinTempDelta = delta } }

        for w in take("Workouts", await exercises, unit: "sessions") {
            edit(w.start) { d in
                var list = d.workouts ?? []
                if !list.contains(where: { $0.id == w.id }) { list.append(w) }
                d.workouts = list.sorted { $0.start < $1.start }
            }
        }

        // Heart rate: each day's load and zone minutes from every reading (there are no zone minutes
        // in Apple Health), keeping 5-minute averages for the charts of the last two weeks.
        let readings = take("Heart rate", await heart, unit: "readings")
            .map { HeartSample(time: $0.startDate, bpm: $0.quantity.doubleValue(for: Self.bpm)) }
        Self.applyHeartRate(readings, to: &days, from: from,
                            keepSamplesFrom: cal.date(byAdding: .day, value: -14, to: today) ?? today,
                            maxHeartRate: maxHeartRate)
        Self.applyHourly(take("Steps by hour", await hourSteps, unit: "hours"), to: &days, from: twoWeeks, \.hourlySteps)
        Self.applyHourly(take("Calories by hour", await hourKcal, unit: "hours"), to: &days, from: twoWeeks, \.hourlyCalories)
        if let line = Self.todayLine(days[today]) { report.append(line) }

        if case .failure(let error) = sleepResult { throw error }
        return (days.values.sorted { $0.date < $1.date }, report)
    }

    // MARK: Queries

    /// One value per calendar day (or per `every`): the total (steps, calories) or the average
    /// (heart rate, breathing).
    private func daily(_ id: HKQuantityTypeIdentifier, unit: HKUnit, sum: Bool, from: Date, to end: Date,
                       every interval: DateComponents = DateComponents(day: 1)) async throws -> [(Date, Double)] {
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: from, end: end)),
            options: sum ? .cumulativeSum : .discreteAverage,
            anchorDate: from,
            intervalComponents: interval)
        return try await query.result(for: Self.store).statistics().compactMap { stats in
            guard let q = sum ? stats.sumQuantity() : stats.averageQuantity() else { return nil }
            return (stats.startDate, q.doubleValue(for: unit))
        }
    }

    private func samples(_ id: HKQuantityTypeIdentifier, from: Date) async throws -> [HKQuantitySample] {
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: from, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: Self.store)
    }

    /// Nights from the sleep records. Apps and devices can each record the same night (the iPhone's
    /// bedtime, the watch, Google Health…), so each night uses the one source that saw the most sleep.
    private func sleepSessions(from: Date) async throws -> [SleepSession] {
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                         predicate: HKQuery.predicateForSamples(withStart: from.addingTimeInterval(-86_400), end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let records = try await query.result(for: Self.store)

        // Records less than 90 minutes apart belong to the same night.
        var nights: [[HKCategorySample]] = []
        var nightEnd = Date.distantPast
        for r in records {
            if nights.isEmpty || r.startDate.timeIntervalSince(nightEnd) > 90 * 60 {
                nights.append([r])
                nightEnd = r.endDate
            } else {
                nights[nights.count - 1].append(r)
                nightEnd = max(nightEnd, r.endDate)
            }
        }

        return nights.compactMap { night -> SleepSession? in
            let bySource = Dictionary(grouping: night) { $0.sourceRevision.source.bundleIdentifier }
            func asleepSeconds(_ list: [HKCategorySample]) -> Double {
                list.filter { Self.stage($0) != nil && Self.stage($0) != .awake }
                    .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            }
            guard let best = bySource.values.max(by: { asleepSeconds($0) < asleepSeconds($1) }),
                  asleepSeconds(best) > 0,
                  let start = best.map(\.startDate).min(), let end = best.map(\.endDate).max(),
                  end >= from else { return nil }
            let stages = best.compactMap { r in Self.stage(r).map { SleepStage(kind: $0, start: r.startDate, end: r.endDate) } }
                .sorted { $0.start < $1.start }
            let awake = stages.filter { $0.kind == .awake }.reduce(0) { $0 + $1.minutes }
            return SleepSession(start: start, end: end, minutesAsleep: asleepSeconds(best) / 60,
                                minutesAwake: awake, stages: stages)
        }
    }

    /// Apple's sleep stages in Halo's terms. "Core" is Apple's name for light sleep; sleep without
    /// stages (older watches, some apps) counts as light. Time in bed only sets the night's edges.
    private static func stage(_ r: HKCategorySample) -> SleepStageKind? {
        switch HKCategoryValueSleepAnalysis(rawValue: r.value) {
        case .awake: return .awake
        case .asleepREM: return .rem
        case .asleepDeep: return .deep
        case .asleepCore, .asleepUnspecified: return .light
        default: return nil
        }
    }

    private func workouts(from: Date) async throws -> [Workout] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: from, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await query.result(for: Self.store).map { w in
            let indoor = (w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) == true
            let distance = [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
                .lazy.compactMap { w.statistics(for: HKQuantityType($0))?.sumQuantity() }.first
            return Workout(id: w.uuid.uuidString,
                           kind: ActivityType(healthKit: w.workoutActivityType, indoor: indoor).rawValue,
                           start: w.startDate, end: w.endDate,
                           calories: w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                           averageHeartRate: w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: Self.bpm),
                           distanceKm: distance?.doubleValue(for: .meterUnit(with: .kilo)))
        }
    }
}

extension ActivityType {
    /// Apple's workout types in Halo's terms.
    init(healthKit type: HKWorkoutActivityType, indoor: Bool) {
        switch type {
        case .running: self = .running
        case .walking: self = .walking
        case .hiking: self = .hiking
        case .cycling: self = indoor ? .indoorCycling : .cycling
        case .swimming: self = .swimming
        case .rowing: self = .rowing
        case .elliptical: self = .elliptical
        case .stairClimbing, .stairs, .stepTraining: self = .stairs
        case .traditionalStrengthTraining: self = .strength
        case .functionalStrengthTraining: self = .functional
        case .highIntensityIntervalTraining: self = .hiit
        case .crossTraining, .mixedCardio: self = .crossTraining
        case .coreTraining: self = .core
        case .yoga: self = .yoga
        case .pilates: self = .pilates
        case .flexibility: self = .stretching
        case .mindAndBody, .taiChi: self = .mindAndBody
        case .cooldown: self = .cooldown
        case .socialDance, .cardioDance, .barre: self = .dance
        case .boxing, .kickboxing: self = .boxing
        case .martialArts, .wrestling: self = .martialArts
        case .jumpRope: self = .jumpRope
        case .climbing: self = .climbing
        case .tennis: self = .tennis
        case .racquetball: self = .padel
        case .badminton: self = .badminton
        case .squash: self = .squash
        case .tableTennis: self = .tableTennis
        case .soccer, .americanFootball, .australianFootball, .rugby: self = .football
        case .basketball: self = .basketball
        case .volleyball: self = .volleyball
        case .golf: self = .golf
        case .downhillSkiing, .crossCountrySkiing: self = .skiing
        case .snowboarding: self = .snowboarding
        case .skatingSports: self = .skating
        case .surfingSports, .paddleSports, .waterSports: self = .surfing
        default: self = .other
        }
    }
}
