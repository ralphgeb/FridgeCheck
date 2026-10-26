import SwiftUI

/// Publishes appearance changes so the whole app redraws in the new colors.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published var appearance: Appearance { didSet { Appearance.save(appearance) } }

    init() { appearance = Appearance.current }

    func apply(_ preset: Preset) {
        var a = Appearance(preset: preset, numberStyle: appearance.numberStyle)
        a.sameInBoth = appearance.sameInBoth
        appearance = a
    }

    func reset() { appearance = .standard }
}

struct SettingsView: View {
    @EnvironmentObject private var store: HealthStore
    @EnvironmentObject private var look: AppearanceStore
    @ObservedObject private var auth = GoogleAuth.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WeekStart.key) private var weekStartsOnMonday = WeekStart.startsOnMonday
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                appearanceSection
                profileSection
                targetsSection
                Section("How the scores work") {
                    explainer("Recovery", "Set each morning: HRV and resting heart rate against your last 30 days, plus last night's sleep.")
                    explainer("Effort", "Today only, from zero at midnight. Half is steps against your step target. Half is heart zone minutes against your daily target: a fat-burn minute counts a quarter, a cardio minute twice, a peak minute three times.")
                    explainer("Cardio load", "How hard your heart worked this week. Halo looks at your heart rate minute by minute against your resting and maximum heart rate. Minutes below the fat-burn zone add nothing; above it they add more the higher you go (about 1 a minute in fat burn, 2 in cardio, 3 in peak). The weekly target follows your last four weeks: Maintain keeps it level, Build adds 10%, Recover lowers it when your recovery is low or you've done much more than usual.")
                    explainer("Sleep", "Time asleep against your need, deep and REM share, efficiency and a steady bedtime.")
                    explainer("Balance", "Six spokes for the week: sleep, HRV level and steadiness, recovery, steps, weekly cardio load and resting heart rate.")
                }
                Section {
                } footer: {
                    Text("Halo reads your data with read-only access and keeps it on this iPhone. Halo isn't a medical device.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(Theme.ink)
        }
    }

    // MARK: Data

    private var accountSection: some View {
        Section {
            if auth.isConnected {
                Label("Fitbit connected", systemImage: "checkmark.circle.fill")
                Button {
                    Task { await store.sync() }
                } label: {
                    HStack {
                        Text("Sync now")
                        Spacer()
                        if store.isSyncing { ProgressView() }
                        else if let d = store.lastSync {
                            Text(d.formatted(.relative(presentation: .named))).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                Button("Disconnect", role: .destructive) {
                    auth.disconnect()
                    Task { await store.accountChanged() }
                }
            } else {
                Button {
                    connecting = true
                    error = nil
                    Task {
                        do {
                            try await auth.connect()
                            await store.accountChanged()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        connecting = false
                    }
                } label: {
                    HStack {
                        Label("Connect Fitbit", systemImage: "link")
                        Spacer()
                        if connecting { ProgressView() }
                    }
                }
                .disabled(connecting)
            }
            if let message = error ?? store.lastError {
                Text(message).font(.footnote).foregroundStyle(Theme.accent)
            }
            if auth.isConnected, !store.syncReport.isEmpty {
                DisclosureGroup("What the last sync found") {
                    ForEach(store.syncReport) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Circle().fill(line.ok ? Theme.ink.opacity(0.5) : Theme.accent).frame(width: 6, height: 6)
                            Text(line.name).font(.system(size: 14))
                            Spacer()
                            Text(line.result).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .font(.system(size: 15))
            }
        } header: {
            Text("Data")
        } footer: {
            Text(auth.isConnected
                 ? "Halo reads sleep, heart, activity, vitals and weight from your Fitbit through Google Health."
                 : "Sign in with the Google account your Fitbit uses. Until then Halo shows sample data.")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Preset.all) { p in
                        Button { withAnimation(.snappy) { look.apply(p) } } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill((scheme == .dark ? p.dark : p.light).background.color)
                                    Circle().inset(by: 7).trim(from: 0, to: 0.72)
                                        .stroke((scheme == .dark ? p.dark : p.light).ink.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                    Circle().fill(p.accent.color).frame(width: 9, height: 9)
                                }
                                .frame(width: 52, height: 52)
                                .overlay(Circle().stroke(look.appearance.presetID == p.id ? Theme.accent : Theme.hairline,
                                                         lineWidth: look.appearance.presetID == p.id ? 2 : 1))
                                Text(p.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }

            ColorPicker("Main color", selection: colorBinding(\.ink), supportsOpacity: false)
            ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
            ColorPicker("Background", selection: colorBinding(\.background), supportsOpacity: false)
            ColorPicker("Cards", selection: colorBinding(\.card), supportsOpacity: false)
            Toggle("Same colors in Light and Dark", isOn: $look.appearance.sameInBoth)

            Picker("Numbers", selection: $look.appearance.numberStyle) {
                ForEach(NumberStyle.allCases) { s in
                    Text(s.title).tag(s)
                }
            }

            HStack(spacing: 16) {
                ZStack {
                    TripleRing(scores: Scores(recovery: 0.82, effort: 0.56, sleep: 0.74), lineWidth: 5, gap: 2.5, showsTip: true)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text("82").font(Theme.number(30)).foregroundStyle(Theme.ink)
                    Text("Preview").haloLabel()
                }
                Spacer()
            }
            .padding(.vertical, 4)

            Button("Reset to Graphite", role: .destructive) { withAnimation { look.reset() } }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Colors you pick here are for \(look.appearance.sameInBoth ? "both Light and Dark mode" : (scheme == .dark ? "Dark mode" : "Light mode")). The widgets follow too.")
        }
        .listRowBackground(Theme.card)
    }

    /// Edits the palette for the current appearance (or both, when they're shared).
    private func colorBinding(_ key: WritableKeyPath<PaletteColors, RGBA>) -> Binding<Color> {
        Binding(
            get: { look.appearance.colors(for: scheme == .dark ? .dark : .light)[keyPath: key].color },
            set: { new in
                var a = look.appearance
                a.presetID = "custom"
                if a.sameInBoth || scheme != .dark { a.light[keyPath: key] = RGBA(new) }
                if a.sameInBoth || scheme == .dark { a.dark[keyPath: key] = RGBA(new) }
                look.appearance = a
            }
        )
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { look.appearance.accent.color },
            set: { new in
                look.appearance.presetID = "custom"
                look.appearance.accent = RGBA(new)
            }
        )
    }

    // MARK: Profile & targets

    private var profileSection: some View {
        Section {
            Picker("Sex", selection: $store.profile.sex) {
                ForEach(Profile.Sex.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $store.profile.birthYear, in: 1930...2012) {
                row("Born", String(store.profile.birthYear))
            }
            Stepper(value: $store.profile.heightCm, in: 120...220, step: 1) {
                row("Height", "\(Int(store.profile.heightCm)) cm")
            }
            Stepper(value: $store.profile.weightKg, in: 35...200, step: 0.5) {
                row("Weight", String(format: "%.1f kg", store.profile.weightKg))
            }
        } header: {
            Text("Body")
        } footer: {
            Text("Used to work out resting calories. A Fitbit-connected scale overrides the weight.")
        }
        .listRowBackground(Theme.card)
    }

    private var targetsSection: some View {
        Section {
            Stepper(value: $store.targets.sleepNeedHours, in: 6...10, step: 0.25) {
                row("Sleep need", Format.duration(store.targets.sleepNeedHours * 60))
            }
            Stepper(value: $store.targets.steps, in: 2_000...25_000, step: 500) {
                row("Steps", Int(store.targets.steps).formatted())
            }
            Stepper(value: $store.targets.zoneMinutes, in: 10...120, step: 5) {
                row("Heart zone minutes", "\(Int(store.targets.zoneMinutes)) a day")
            }
            Picker("Cardio focus", selection: $store.targets.cardioFocus) {
                ForEach(CardioFocus.allCases) { Text($0.title).tag($0) }
            }
            Picker("Week starts on", selection: $weekStartsOnMonday) {
                Text("Monday").tag(true)
                Text("Sunday").tag(false)
            }
            .onChange(of: weekStartsOnMonday) { _, _ in store.refreshScores() }
        } header: {
            Text("Targets")
        } footer: {
            let week = store.cardioWeek(endingOn: .now)
            Text("\(store.targets.cardioFocus.detail) This week: \(week.focus.title), a cardio load of \(Int(week.target)).")
        }
        .listRowBackground(Theme.card)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).font(Theme.number(16, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }

    private func explainer(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 2)
        .listRowBackground(Theme.card)
    }
}
