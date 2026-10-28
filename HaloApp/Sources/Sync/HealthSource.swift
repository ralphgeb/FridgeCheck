import Foundation

/// Where Halo reads your data from. Each source turns its own data into Halo's day records,
/// so the scores never need to know which band it came from.
enum DataSource: String, CaseIterable, Identifiable, Codable {
    case google, appleHealth, whoop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Fitbit (Google Health)"
        case .appleHealth: return "Apple Health"
        case .whoop: return "Whoop"
        }
    }

    /// The band this source suits best, for the picker.
    var devices: String {
        switch self {
        case .google: return "Fitbit and Pixel Watch"
        case .appleHealth: return "Apple Watch, Garmin, Oura and anything that writes to Apple Health"
        case .whoop: return "Whoop 4.0 and 5.0, through your Whoop account"
        }
    }

    @MainActor var isConnected: Bool {
        switch self {
        case .google: return GoogleAuth.shared.isConnected
        case .appleHealth: return HealthKitClient.isConnected
        case .whoop: return WhoopAuth.shared.isConnected
        }
    }

    /// The source in use (set in Settings). Fitbit until you pick another.
    static var current: DataSource {
        get { UserDefaults.standard.string(forKey: key).flatMap(DataSource.init(rawValue:)) ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    private static let key = "sync.source"

    /// A reader for this source. `profile` gives the resting calories Whoop's totals are split by;
    /// `heartSince` is where the heart-rate readings the app already has end.
    @MainActor func client(profile: Profile, heartSince: Date? = nil) -> HealthSource {
        switch self {
        case .google: return GoogleHealthClient(token: { try await GoogleAuth.shared.accessToken() }, heartSince: heartSince)
        case .appleHealth: return HealthKitClient()
        case .whoop: return WhoopClient(token: { try await WhoopAuth.shared.accessToken() },
                                        restingKcalPerDay: profile.restingCalories(), heartSince: heartSince)
        }
    }
}

/// One line of the sync report in Settings: what came back for each kind of data.
struct SyncReportLine: Identifiable, Hashable {
    let name: String
    let result: String
    let ok: Bool
    var id: String { name }
}

/// Something Halo can sync from.
protocol HealthSource {
    /// The last `count` days, oldest first, with a report of what came back for each kind of data.
    /// `maxHeartRate` sets the top of the heart-rate zones used to work out cardio load.
    func fetchDays(_ count: Int, maxHeartRate: Double) async throws -> (days: [DayMetrics], report: [SyncReportLine])
}

extension HealthSource {
    /// A missing type (not supported by the device, or no data) shouldn't break the others,
    /// but it goes in the report so it's easy to see what's missing.
    static func take<T>(_ name: String, _ result: Result<[T], Error>, unit: String = "days",
                        into report: inout [SyncReportLine]) -> [T] {
        switch result {
        case .success(let items):
            report.append(SyncReportLine(name: name, result: items.isEmpty ? "No data" : "\(items.count) \(unit)", ok: !items.isEmpty))
            return items
        case .failure(let error):
            report.append(SyncReportLine(name: name, result: error.localizedDescription, ok: false))
            return []
        }
    }

    func attempt<T>(_ work: () async throws -> [T]) async -> Result<[T], Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    /// Each day's cardio load and zone minutes from every heart-rate reading, keeping 5-minute
    /// averages for the charts on days from `keepSamplesFrom`.
    static func applyHeartRate(_ readings: [HeartSample], to days: inout [Date: DayMetrics], from: Date,
                               keepSamplesFrom: Date, maxHeartRate: Double) {
        let cal = Calendar.current
        let minutes = HeartMinutes.buckets(readings)
        for (day, samples) in Dictionary(grouping: readings, by: { cal.startOfDay(for: $0.time) }) where day >= from {
            var d = days[day] ?? DayMetrics(date: day)
            let (load, zones) = CardioLoad.fromHeartRate(samples, resting: restingHeartRate(on: day, in: days), max: maxHeartRate)
            d.heartLoad = load
            d.heartZones = zones
            if day >= keepSamplesFrom {
                d.heartRate = fiveMinuteAverages(samples)
                // the store lays these over the minutes it already has and works the day out again
                d.minuteHeartRate = minutes[day]
            }
            days[day] = d
        }
    }

    /// The day's resting heart rate, or the latest one before it while the band hasn't worked the
    /// day's out yet (usually until you've been awake a while). Your long-run average sits lower
    /// and would put the zone limits too low, so it's only the last resort.
    static func restingHeartRate(on day: Date, in days: [Date: DayMetrics]) -> Double {
        if let r = days[day]?.restingHeartRate { return r }
        let before = days.values.filter { $0.date < day && $0.restingHeartRate != nil }.max { $0.date < $1.date }
        return before?.restingHeartRate ?? ScoreEngine.mean(days.values.compactMap(\.restingHeartRate)) ?? 60
    }

    /// One reading per 5 minutes (the average), which is plenty for a chart and keeps the cache small.
    static func fiveMinuteAverages(_ samples: [HeartSample]) -> [HeartSample] {
        let buckets = Dictionary(grouping: samples) { Int($0.time.timeIntervalSince1970 / 300) }
        return buckets.keys.sorted().compactMap { key in
            guard let group = buckets[key], !group.isEmpty else { return nil }
            let bpm = group.map(\.bpm).reduce(0, +) / Double(group.count)
            return HeartSample(time: Date(timeIntervalSince1970: Double(key) * 300), bpm: bpm.rounded())
        }
    }

    /// Hour-by-hour totals (each with the hour it starts) as 24 values per day, from midnight.
    static func applyHourly(_ points: [(Date, Double)], to days: inout [Date: DayMetrics], from: Date,
                            _ field: WritableKeyPath<DayMetrics, [Double]?>) {
        let cal = Calendar.current
        for (day, items) in Dictionary(grouping: points, by: { cal.startOfDay(for: $0.0) }) where day >= from {
            var hours = [Double](repeating: 0, count: 24)
            for (t, v) in items { hours[cal.component(.hour, from: t)] += v }
            var d = days[day] ?? DayMetrics(date: day)
            d[keyPath: field] = hours
            days[day] = d
        }
    }

    /// Nightly temperatures as the change from the previous 30 nights (needs three), the way Fitbit
    /// shows skin temperature.
    static func changeFromUsual(_ nightly: [(Date, Double)]) -> [(Date, Double)] {
        let sorted = nightly.sorted { $0.0 < $1.0 }
        return sorted.indices.compactMap { i in
            let before = sorted[max(0, i - 30)..<i].map { $0.1 }
            guard before.count >= 3, let usual = ScoreEngine.mean(before) else { return nil }
            return (sorted[i].0, sorted[i].1 - usual)
        }
    }

    /// A line showing what today looks like so far, to check against the band's own app.
    static func todayLine(_ t: DayMetrics?) -> SyncReportLine? {
        guard let t else { return nil }
        let z = t.zoneMinutes
        let zones = z.map { "zones \(Int($0.fatBurn))/\(Int($0.cardio))/\(Int($0.peak)) min" } ?? "no zones"
        let fromHeart = t.heartZones.map { " (from heart rate \(Int($0.fatBurn))/\(Int($0.cardio))/\(Int($0.peak)))" } ?? ""
        return SyncReportLine(name: "Today so far",
                              result: "\((t.steps ?? 0).formatted()) steps · \(zones)\(fromHeart) · load \(Int((t.cardioLoad ?? 0).rounded()))",
                              ok: true)
    }
}
