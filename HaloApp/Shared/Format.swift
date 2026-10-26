import Foundation

enum Format {
    /// 442 -> "7h 22m"
    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    /// "Today", "Yesterday", or "Mon 20 Oct"
    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "19 – 25 Oct", "28 Sep – 4 Oct", or "May – Oct 2026" for long spans
    static func range(_ start: Date, _ end: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: start, to: end).day ?? 0
        let month = { (d: Date) in d.formatted(.dateTime.month(.abbreviated)) }
        let day = { (d: Date) in "\(cal.component(.day, from: d))" }
        if days > 45 {
            return "\(month(start)) – \(month(end)) \(cal.component(.year, from: end))"
        }
        if cal.isDate(start, equalTo: end, toGranularity: .month) {
            return "\(day(start)) – \(day(end)) \(month(end))"
        }
        return "\(day(start)) \(month(start)) – \(day(end)) \(month(end))"
    }
}
