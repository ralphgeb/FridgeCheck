import SwiftUI
import WidgetKit

@main
struct HaloWidgets: WidgetBundle {
    var body: some Widget {
        HaloRingsWidget()
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

    // Halo's single ring for recovery, big and near the top, with all three scores underneath.
    private var small: some View {
        VStack(spacing: 10) {
            Ring(progress: s.recovery ?? 0, lineWidth: 11)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 0) {
                ForEach(ScoreKind.allCases) { k in
                    VStack(spacing: 0) {
                        Text(value(k)?.percentText ?? "–")
                            .font(Theme.number(14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(k.title.uppercased())
                            .font(.system(size: 6.5, weight: .bold)).tracking(0.3)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, -4)
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
            Text(s.recovery?.percentText ?? "–").font(.system(size: 15, weight: .semibold))
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
                    Text(value(k)?.percentText ?? "–").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Balance (radar) widget

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
