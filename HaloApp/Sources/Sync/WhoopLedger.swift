import Foundation

/// Every Whoop record Halo has read, kept on the phone. A sync asks Whoop only for what's new (plus
/// the last couple of days, which Whoop still rescores), lays it over these, and the days are then
/// worked out from all of them, always the same way. So a force close never starts from scratch,
/// and a day only changes when Whoop's records for it do.
struct WhoopLedger: Codable {
    struct Cycle: Codable {
        var id: String
        var start: Date
        var end: Date?              // nil while you're in it
        var kilojoule: Double?
        var strain: Double?
        var averageHeartRate: Double?
        var maxHeartRate: Double?
        var steps: Double?          // over the cycle; nil when the band wasn't worn
    }

    struct Sleep: Codable {
        var id: String
        var cycleId: String?
        var start: Date
        var end: Date
        var nap: Bool
        var light: Double           // minutes
        var deep: Double
        var rem: Double
        var awake: Double
        var respiratoryRate: Double?
    }

    struct Recovery: Codable {
        var cycleId: String
        var sleepId: String?
        var created: Date?
        var hrv: Double?
        var restingHeartRate: Double?
        var spo2: Double?
        var skinTemp: Double?
    }

    struct Workout: Codable {
        var id: String
        var sport: String
        var start: Date
        var end: Date
        var kilojoule: Double?
        var strain: Double?
        var averageHeartRate: Double?
        var maxHeartRate: Double?
        var distanceMeter: Double?
        /// Minutes in Whoop's zones 0–5 (shares of your max heart rate: under 50%, 50–60 … 90–100%).
        var zones: [Double]?
    }

    var cycles: [String: Cycle] = [:]
    var sleeps: [String: Sleep] = [:]
    var recoveries: [String: Recovery] = [:]      // by cycle
    var workouts: [String: Workout] = [:]
    var maxHeartRate: Double?                     // the max Whoop sets your zones from
    var weightKg: Double?
    /// The earliest start the ledger has every record from.
    var coveredFrom: Date?
    /// Records kept before Whoop shared steps have none: read them all again once.
    var hasSteps: Bool?

    /// Where the newest records start: the next sync reads from a little before it.
    var latestStart: Date? {
        (cycles.values.map(\.start) + sleeps.values.map(\.start) + workouts.values.map(\.start)).max()
    }

    var isEmpty: Bool { cycles.isEmpty && sleeps.isEmpty && workouts.isEmpty }

    // MARK: Saving

    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("whoop.json")

    static func load() -> WhoopLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? decoder.decode(WhoopLedger.self, from: data) else { return WhoopLedger() }
        return ledger
    }

    /// Returns why not, if it couldn't save.
    @discardableResult
    func save() -> String? {
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(self).write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Forget everything (another source, or signed out).
    static func clear() { try? FileManager.default.removeItem(at: url) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    // MARK: Merging

    /// Lays freshly read records over the stored ones. Where a whole collection came back from
    /// `since` onwards, records from then on that Whoop no longer has (a deleted workout, a nap
    /// rescored as sleep) are dropped.
    mutating func merge<T>(_ fresh: [T], into keyPath: WritableKeyPath<WhoopLedger, [String: T]>,
                           id: (T) -> String, start: (T) -> Date?, prunedFrom since: Date?) {
        if let since {
            let kept = Set(fresh.map(id))
            self[keyPath: keyPath] = self[keyPath: keyPath].filter { key, value in
                guard let s = start(value) else { return true }
                return s < since.addingTimeInterval(60) || kept.contains(key)
            }
        }
        for item in fresh { self[keyPath: keyPath][id(item)] = item }
    }
}
