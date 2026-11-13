import SwiftUI
import UserNotifications

/// Two notes a day, both off your own data: one in the morning once last night's sleep is in,
/// and one in the evening before your usual bedtime about the day and the night ahead. The words
/// change from day to day (never the same one twice in a row), and match how the day went.
@MainActor
enum HaloNotifications {
    static let morningKey = "notify.morning"
    static let eveningKey = "notify.evening"
    private static let askedKey = "notify.asked"
    private static let morningSentKey = "notify.morningSent"
    private static let eveningID = "halo.evening"
    private static let morningID = "halo.morning"

    static var morningOn: Bool { UserDefaults.standard.object(forKey: morningKey) as? Bool ?? true }
    static var eveningOn: Bool { UserDefaults.standard.object(forKey: eveningKey) as? Bool ?? true }

    /// Asks once, the first time there's real data to talk about.
    static func askOnce() async {
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Asks (when turned on in Settings); false if notifications are off for Halo in iOS Settings.
    static func ask() async -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// After every sync: the morning note if last night has just come in, and tonight's note
    /// written again with the day so far.
    static func afterSync(_ store: HealthStore) async {
        guard !store.showingSample, store.source.isConnected, !store.days.isEmpty else { return }
        if UIApplication.shared.applicationState == .active { await askOnce() }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        await morning(store)
        await evening(store)
    }

    // MARK: Morning

    private static func morning(_ store: HealthStore) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let stamp = String(Int(today.timeIntervalSince1970))
        let defaults = UserDefaults.standard
        guard morningOn, defaults.string(forKey: morningSentKey) != stamp else { return }
        let hour = cal.component(.hour, from: .now)
        guard (4..<13).contains(hour), let day = store.day(today), let sleep = day.sleep,
              Date.now.timeIntervalSince(sleep.end) < 6 * 3600 else { return }
        let s = store.scores(for: today)
        guard s.recovery != nil || s.sleep != nil else { return }
        defaults.set(stamp, forKey: morningSentKey)
        // you're looking at the app already: nothing to tell you
        guard UIApplication.shared.applicationState != .active else { return }
        let facts = MorningFacts(
            recovery: s.recovery.map { Int(($0 * 100).rounded()) },
            sleepScore: s.sleep.map { Int(($0 * 100).rounded()) },
            asleep: Format.duration(sleep.minutesAsleep),
            short: sleep.minutesAsleep < store.targets.sleepNeedHours * 60 - 30,
            hrv: day.hrv.map { Int($0.rounded()) },
            rhr: day.restingHeartRate.map { Int($0.rounded()) },
            woke: Format.time(sleep.end))
        let (title, body) = pick(morningLines(facts), key: "notify.morningLast.\(facts.level)")
        await post(id: morningID, title: title, body: body, url: "halo://sleep", at: nil)
    }

    struct MorningFacts {
        var recovery: Int?
        var sleepScore: Int?
        var asleep: String
        var short: Bool
        var hrv: Int?
        var rhr: Int?
        var woke: String
        var level: Int { recovery.map { $0 >= 67 ? 2 : ($0 >= 34 ? 1 : 0) } ?? (sleepScore.map { $0 >= 80 ? 2 : ($0 >= 60 ? 1 : 0) } ?? 1) }
    }

    private static func morningLines(_ f: MorningFacts) -> [(String, String)] {
        let r = f.recovery.map { "\($0)%" } ?? "–"
        let sleepScore = f.sleepScore.map { "\($0)" } ?? "–"
        let hrv = f.hrv.map { "HRV \($0) ms" } ?? "a calm heart"
        switch f.level {
        case 2: return [
            ("Recovery \(r). You're charged up", "\(f.asleep) of sleep did its job. Today's a day to go for it."),
            ("Green light this morning", "Recovery \(r) after \(f.asleep) asleep. Plan something you'll enjoy pushing."),
            ("Well slept, well recovered", "Sleep score \(sleepScore), recovery \(r). Make the most of it."),
            ("Your body says yes", "\(hrv) and recovery \(r). A hard workout will land well today."),
            ("That's a good night", "\(f.asleep) asleep and recovery at \(r). See what's behind the numbers."),
            ("Ready when you are", "Recovery \(r). Fresh legs, steady heart. Go and use them."),
            ("Morning! Recovery \(r)", "One of your better nights: \(f.asleep), sleep score \(sleepScore)."),
            ("Fully topped up", "Recovery \(r) with \(hrv). Today can take a bit more."),
            ("Rise and shine, literally", "\(f.asleep) of sleep and recovery \(r). Your night, in detail, inside."),
            ("Strong start", "Recovery \(r), sleep score \(sleepScore). The rest of the day is yours."),
        ]
        case 1: return [
            ("Recovery \(r). A steady day", "\(f.asleep) asleep. Train as usual, keep the hardest efforts short."),
            ("Middle of the road", "Recovery \(r) after \(f.asleep). Good for a normal day, not for a record."),
            ("Morning check-in", "Sleep score \(sleepScore), recovery \(r). See what pulled it either way."),
            ("Not bad, not your best", "\(f.asleep) of sleep, recovery \(r). A moderate session fits today."),
            ("Recovery \(r) this morning", f.short ? "A little short on sleep at \(f.asleep). Keep it easy-ish and bank an early night." : "\(f.asleep) of sleep. Steady is the word for today."),
            ("You're good to go, gently", "Recovery \(r). Move, but leave something in the tank."),
            ("Halfway charged", "\(hrv), recovery \(r). Today rewards steady over heroic."),
            ("Your night in numbers", "\(f.asleep) asleep, woke at \(f.woke), recovery \(r)."),
            ("Steady start", "Recovery \(r) with a sleep score of \(sleepScore). Tap to see the details."),
            ("A solid, ordinary night", "\(f.asleep) and recovery \(r). Normal day, normal plans."),
        ]
        default: return [
            ("Recovery \(r). Go easy today", "\(f.asleep) of sleep wasn't quite enough. Your body's still catching up."),
            ("Take it gently this morning", "Recovery \(r). A walk beats a hard workout today."),
            ("Rough night?", "\(f.asleep) asleep, sleep score \(sleepScore). Be kind to yourself today."),
            ("Low battery", "Recovery \(r). Water, good food and an early night will turn it around."),
            ("Your body asks for a break", "\(hrv), recovery \(r). Rest is training too."),
            ("Slow start today", "Recovery \(r) after \(f.asleep). Save the big efforts for later in the week."),
            ("Recovery \(r): rest day energy", "Skip the intervals. See what dragged last night down."),
            ("Running on reserve", "\(f.asleep) of sleep and recovery \(r). Tonight's sleep is your best fix."),
            ("Easy does it", "Recovery \(r). Light movement helps more than pushing today."),
            ("Recharge day", "Sleep score \(sleepScore), recovery \(r). Plan for an early night."),
        ]
        }
    }

    // MARK: Evening

    private static func evening(_ store: HealthStore) async {
        let center = UNUserNotificationCenter.current()
        guard eveningOn else {
            center.removePendingNotificationRequests(withIdentifiers: [eveningID])
            return
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        // 45 minutes before your usual bedtime (from the last two weeks), between 8 pm and 11:30 pm
        let starts = store.days.suffix(14).compactMap { d -> Double? in
            guard let s = d.sleep else { return nil }
            // minutes after 6 pm the evening before
            let evening = d.date.addingTimeInterval(-6 * 3600)
            return s.start.timeIntervalSince(evening) / 60
        }
        let usual = starts.isEmpty ? 270 : starts.sorted()[starts.count / 2]       // 10:30 pm
        let sendMinutes = min(330, max(120, usual - 45))                              // 8 pm – 11:30 pm
        guard let send = cal.date(byAdding: .minute, value: Int(sendMinutes) + 18 * 60, to: today),
              send > .now.addingTimeInterval(5 * 60) else { return }
        let day = store.day(today)
        let s = store.scores(for: today)
        let bed = Format.time(send.addingTimeInterval(45 * 60))
        let wake = Format.time(send.addingTimeInterval(45 * 60 + store.targets.sleepNeedHours * 3600 + 15 * 60))
        let facts = EveningFacts(
            steps: day?.steps,
            effort: s.effort.map { Int(($0 * 100).rounded()) },
            recovery: s.recovery.map { Int(($0 * 100).rounded()) },
            lastNight: day?.sleep.map { Format.duration($0.minutesAsleep) },
            workouts: store.activities(on: today).count,
            bed: bed, wake: wake,
            need: Format.duration(store.targets.sleepNeedHours * 60))
        let (title, body) = pick(eveningLines(facts), key: "notify.eveningLast.\(facts.level)", stableFor: today)
        await post(id: eveningID, title: title, body: body, url: "halo://today", at: send)
    }

    struct EveningFacts {
        var steps: Int?
        var effort: Int?
        var recovery: Int?
        var lastNight: String?
        var workouts: Int
        var bed: String
        var wake: String
        var need: String
        /// 2 a big day, 1 a usual one, 0 a quiet one
        var level: Int {
            if let effort { return effort >= 70 || workouts >= 2 ? 2 : (effort >= 35 || workouts == 1 ? 1 : 0) }
            if let steps { return steps >= 12_000 ? 2 : (steps >= 6_000 ? 1 : 0) }
            return 1
        }
    }

    private static func eveningLines(_ f: EveningFacts) -> [(String, String)] {
        let steps = f.steps.map { "\($0.formatted()) steps" } ?? "your day"
        let effort = f.effort.map { "effort \($0)%" } ?? "a full day"
        let night = f.lastNight.map { "after \($0) of sleep" } ?? "today"
        let moves = f.workouts == 1 ? "a workout" : "\(f.workouts) workouts"
        switch f.level {
        case 2: return [
            ("Big day: \(effort)", "\(steps) and \(moves). Your body earns its sleep tonight. Bed by \(f.bed)?"),
            ("You moved today", "\(steps), \(effort). Sleep is where it turns into fitness. Aim for \(f.bed)."),
            ("What a day", "\(effort) \(night). \(f.need) tonight sets up tomorrow nicely."),
            ("Time to wind down", "\(steps) done. Lights out by \(f.bed) and you're up at \(f.wake) fully charged."),
            ("Hard work, now rest", "\(moves) and \(steps). Recovery happens tonight, not tomorrow."),
            ("Strong day in the bank", "\(effort). Put the phone down by \(f.bed) and let your body rebuild."),
            ("\(steps) and counting", "A big one. An early night locks in the gains."),
            ("Your legs will thank you", "\(effort) today. \(f.need) of sleep is the best stretch there is."),
            ("Day done, and done well", "\(steps), \(moves). Bed by \(f.bed) for a good recovery tomorrow."),
            ("Effort \(f.effort.map { "\($0)%" } ?? "high"). Nice", "Sleep is where it pays off. See how today compares."),
        ]
        case 1: return [
            ("Your day in one line", "\(steps), \(effort). Bed by \(f.bed) gets you your \(f.need)."),
            ("Evening check-in", "A steady day \(night). Wind down soon for a good start tomorrow."),
            ("Nearly bedtime", "\(steps) today. In bed by \(f.bed), up at \(f.wake), feeling it."),
            ("A good, steady day", "\(effort). Keep tonight consistent and recovery follows."),
            ("Time to slow down", "\(steps) done. Dim the lights, park the screen, aim for \(f.bed)."),
            ("Today, wrapped", "\(effort), \(steps). Tap to see how it stacks up against your week."),
            ("Sleep o'clock is coming", "Your usual bedtime is near. \(f.need) tonight keeps your sleep bank healthy."),
            ("How was today?", "\(steps) and \(effort). The best thing for tomorrow: bed by \(f.bed)."),
            ("Wind-down time", "A balanced day \(night). Same bedtime as usual makes for better sleep."),
            ("Day's nearly done", "\(steps). An early-ish night means a stronger recovery score."),
        ]
        default: return [
            ("Quiet day today", "\(steps) so far. A short walk before bed helps you fall asleep faster."),
            ("Rest day, done right", "Low effort today. Your body uses tonight to catch up. Bed by \(f.bed)."),
            ("Easy day in the books", "\(steps). Keep the evening calm and aim for \(f.need) of sleep."),
            ("Recharge night", "A light day \(night). Sleep well and tomorrow could be a good one."),
            ("Slow and steady", "\(steps) today. In bed by \(f.bed), up at \(f.wake)."),
            ("Time to recharge", "Not much load today. Perfect setup for a deep night's sleep."),
            ("A gentle day", "\(steps). Wind down early and let your recovery climb."),
            ("Lights out soon?", "A rest day is only as good as the sleep after it. Aim for \(f.bed)."),
            ("Your body thanks you", "An easy day \(night). Tonight's sleep does the rest."),
            ("Evening reset", "\(steps). Screens off by \(f.bed) and tomorrow starts fresh."),
        ]
        }
    }

    // MARK: Helpers

    /// A line from the set, never the one used last time; for the evening the same one all day
    /// (it's written again after every sync).
    private static func pick(_ lines: [(String, String)], key: String, stableFor day: Date? = nil) -> (String, String) {
        let defaults = UserDefaults.standard
        let dayKey = key + ".day"
        if let day {
            let stamp = day.timeIntervalSince1970
            if defaults.double(forKey: dayKey) == stamp {
                let i = defaults.integer(forKey: key)
                if lines.indices.contains(i) { return lines[i] }
            }
            defaults.set(stamp, forKey: dayKey)
        }
        let last = defaults.object(forKey: key) as? Int
        var i = Int.random(in: 0..<lines.count)
        if i == last { i = (i + 1 + Int.random(in: 0..<(lines.count - 1))) % lines.count }
        defaults.set(i, forKey: key)
        return lines[i]
    }

    private static func post(id: String, title: String, body: String, url: String, at date: Date?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url]
        content.threadIdentifier = id
        let trigger: UNNotificationTrigger?
        if let date {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        } else {
            trigger = nil
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Off in Settings: nothing waiting either.
    static func cancelEvening() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [eveningID])
    }
}

/// Tapping a note opens the page it's about.
final class NotificationOpener: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationOpener()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) else { return }
        await MainActor.run { UIApplication.shared.open(url) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
