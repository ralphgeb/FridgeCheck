import Foundation

/// Which day a week starts on, for cardio load, weekly graphs and the calendar.
/// Set in Settings; until then it follows the phone's region.
enum WeekStart {
    static let key = "week.startsOnMonday"

    static var startsOnMonday: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? (Calendar.current.firstWeekday == 2) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = startsOnMonday ? 2 : 1
        return c
    }

    /// The first day of the week that contains `date`.
    static func start(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
