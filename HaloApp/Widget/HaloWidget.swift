import SwiftUI
import WidgetKit

@main
struct HaloWidgets: WidgetBundle {
    var body: some Widget {
        HaloRingsWidget()
        HaloForecastWidget()
        HaloBalanceWidget()
    }
}

struct HaloEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct HaloProvider: TimelineProvider {
    func placeholder(in context: Context) -> HaloEntry {
        HaloEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (HaloEntry) -> Void) {
        Appearance.current = Appearance.load()
        completion(HaloEntry(date: .now, snapshot: context.isPreview ? .sample : (WidgetSnapshot.load() ?? .sample)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HaloEntry>) -> Void) {
        // The app pushes a new snapshot after each sync; this is only a fallback refresh.
        Appearance.current = Appearance.load()
        let entry = HaloEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .sample)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(2 * 3600))))
    }
}

struct HaloRingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: HaloProvider()) { entry in
            HaloWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
                .widgetURL(URL(string: "halo://today"))
        }
        .configurationDisplayName("Halo")
        .description("Recovery, effort and sleep at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct HaloWidgetView: View {
    let entry: HaloEntry
    @Environment(\.widgetFamily) private var family

    private var s: WidgetSnapshot { entry.snapshot }

    private func value(_ k: ScoreKind) -> Double? {
        switch k {
        case .recovery: return s.recovery
        case .effort: return s.effort
        case .sleep: return s.sleep
        }
    }

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    // Halo's single ring for recovery, with all three scores underneath.
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Halo").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(s.recovery?.percentText ?? "–").font(Theme.number(13)).foregroundStyle(Theme.accent)
            }
            Ring(progress: s.recovery ?? 0, lineWidth: 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 0) {
                ForEach(ScoreKind.allCases) { k in
                    VStack(spacing: 0) {
                        Text(value(k)?.percentText ?? "–")
                            .font(Theme.number(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(k.title.uppercased())
                            .font(.system(size: 6.5, weight: .bold)).tracking(0.3)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // Three dials side by side with labels.
    private var medium: some View {
        HStack(spacing: 14) {
            ForEach(ScoreKind.allCases) { k in
                VStack(spacing: 8) {
                    ZStack {
                        Ring(progress: value(k) ?? 0, lineWidth: 8)
                        Text(value(k)?.percentText ?? "–")
                            .font(Theme.number(24))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(k.title).haloLabel()
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var circular: some View {
        Gauge(value: s.recovery ?? 0) {
            Image(systemName: "bolt.heart")
        } currentValueLabel: {
            Text(s.recovery?.percentText ?? "–").font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(ScoreKind.allCases) { k in
                HStack(spacing: 6) {
                    Text(k.title).font(.system(size: 11, weight: .semibold)).frame(width: 58, alignment: .leading)
                    Gauge(value: value(k) ?? 0) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .widgetAccentable()
                    Text(value(k)?.percentText ?? "–").font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Balance (radar) widget

// MARK: - Body forecast widget

/// Your readiness as a weather report: the conditions are how ready you are, the "temperature" is
/// the readiness score, high and low are HRV and resting heart rate, and tonight's outlook is when
/// to go to bed.
struct HaloForecastWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.forecastKind, provider: HaloProvider()) { entry in
            ForecastWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
                .widgetURL(URL(string: "halo://fitness"))
        }
        .configurationDisplayName("Body Forecast")
        .description("Today's readiness as a weather report, and tonight's bedtime.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The day's conditions, from readiness (the same bands as the Fitness tab).
struct Forecast {
    let symbol: String
    let sky: String
    let advice: String
    let bright: Bool       // sunny: the symbol takes the accent

    init(readiness r: Double?) {
        let v: (String, String, String, Bool)
        switch r ?? -1 {
        case 0.8...: v = ("sun.max.fill", "Clear skies", "Go break something", true)
        case 0.6..<0.8: v = ("cloud.sun.fill", "Sunny spells", "Ready for exercise", true)
        case 0.4..<0.6: v = ("cloud.fill", "Overcast", "Keep it light", false)
        case 0.25..<0.4: v = ("cloud.drizzle.fill", "Showers", "Take a day off", false)
        case 0..<0.25: v = ("cloud.bolt.rain.fill", "Storm warning", "Take a day off", false)
        default: v = ("cloud.fog.fill", "No reading yet", "Wear it to sleep", false)
        }
        symbol = v.0; sky = v.1; advice = v.2; bright = v.3
    }
}

struct ForecastWidgetView: View {
    let entry: HaloEntry
    @Environment(\.widgetFamily) private var family

    private var s: WidgetSnapshot { entry.snapshot }
    private var f: Forecast { Forecast(readiness: s.readiness) }

    var body: some View {
        if family == .systemMedium {
            HStack(spacing: 16) {
                today
                Rectangle().fill(Theme.track).frame(width: 1).padding(.vertical, 4)
                tonight
            }
        } else {
            today
        }
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Body forecast").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.readiness.map { "\(Int(($0 * 100).rounded()))°" } ?? "–")
                    .font(Theme.number(40)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: f.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 26))
                    .foregroundStyle(f.bright ? Theme.accent : Theme.secondary)
            }
            Spacer(minLength: 2)
            Text(f.sky).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(f.advice).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            // like a weather app's high and low
            HStack(spacing: 8) {
                Text("H \(s.hrv.map { "\(Int($0.rounded())) ms" } ?? "–")")
                Text("L \(s.restingHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "–")")
            }
            .font(Theme.number(11, weight: .semibold)).foregroundStyle(Theme.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tonight: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tonight").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(s.bedtime.map(Format.time) ?? "–").font(Theme.number(26)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "moon.stars.fill").symbolRenderingMode(.hierarchical)
                    .font(.system(size: 20)).foregroundStyle(Theme.secondary)
            }
            Text("Lights out").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 4)
            Text("Last night").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            Text(s.minutesAsleep.map { "\(Int($0) / 60)h \(Int($0) % 60)m" } ?? "–")
                .font(Theme.number(15, weight: .semibold)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HaloBalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.balanceKind, provider: HaloProvider()) { entry in
            BalanceWidgetView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
                .widgetURL(URL(string: "halo://today"))
        }
        .configurationDisplayName("Halo Balance")
        .description("How rounded your week is: sleep, HRV, recovery, steps and cardio.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BalanceWidgetView: View {
    let entry: HaloEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let axes = entry.snapshot.balance
        if family == .systemMedium {
            HStack(spacing: 14) {
                RadarChart(axes: axes, showsLabels: false)
                    .overlay {
                        Text(axes.overall.percentText).font(Theme.number(15)).foregroundStyle(Theme.ink)
                            .padding(5).background(Theme.background.opacity(0.85), in: Capsule())
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Balance").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                        .padding(.bottom, 2)
                    ForEach(axes) { a in
                        HStack {
                            Text(a.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            Spacer()
                            Text(a.value.percentText).font(Theme.number(11, weight: .semibold))
                                .foregroundStyle(a.id == axes.min(by: { $0.value < $1.value })?.id ? Theme.accent : Theme.ink)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Balance").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(axes.overall.percentText).font(Theme.number(13)).foregroundStyle(Theme.accent)
                }
                RadarChart(axes: axes, showsLabels: false)
            }
        }
    }
}
