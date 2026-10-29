import SwiftUI

/// Publishes appearance changes so the whole app redraws in the new colors.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published var appearance: Appearance { didSet { Appearance.save(appearance) } }

    init() { appearance = Appearance.current }

    func apply(_ preset: Preset) {
        var a = Appearance(preset: preset, numberStyle: appearance.numberStyle)
        a.sameInBoth = appearance.sameInBoth
        a.mode = appearance.mode
        appearance = a
    }

    /// Back to Halo's original colors and numbers; light or dark stays as you set it.
    func reset() {
        var a = Appearance.standard
        a.mode = appearance.mode
        appearance = a
    }
}

/// Settings: a short list of cards, each opening its own page.
struct SettingsView: View {
    @EnvironmentObject private var store: HealthStore
    @EnvironmentObject private var look: AppearanceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sources") {
                    NavigationLink { SourcesSettings() } label: {
                        SettingsRow(symbol: "dot.radiowaves.left.and.right", title: store.source.title, detail: sourceDetail)
                    }
                }
                .listRowBackground(Theme.card)

                Section("You") {
                    NavigationLink { AboutYouSettings() } label: {
                        SettingsRow(symbol: "person", title: "About you", detail: aboutDetail)
                    }
                    NavigationLink { TargetsSettings() } label: {
                        SettingsRow(symbol: "target", title: "Health targets", detail: targetsDetail)
                    }
                }
                .listRowBackground(Theme.card)

                // the color sets and the reset sit on the page itself, not in a card
                Section {
                    ColorSetsStrip()
                        .listRowInsets(EdgeInsets())
                    HStack {
                        Spacer()
                        Button("Reset to original colors") { withAnimation { look.reset() } }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                } header: {
                    Text("Colors")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section("App") {
                    NavigationLink { AppearanceSettings() } label: {
                        SettingsRow(symbol: "paintpalette", title: "Appearance", detail: look.appearance.mode.title)
                    }
                    NavigationLink { ScoresExplainer() } label: {
                        SettingsRow(symbol: "questionmark.circle", title: "How the scores work", detail: nil)
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                } footer: {
                    Text("Halo reads your data with read-only access and keeps it on this iPhone. Nothing goes to the cloud. Halo isn't a medical device.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.ink)
    }

    private var sourceDetail: String {
        guard store.source.isConnected else { return "Not connected · sample data" }
        if store.isSyncing { return "Syncing…" }
        if let d = store.lastSync { return "Synced \(d.formatted(.relative(presentation: .named)))" }
        return "Connected"
    }

    private var aboutDetail: String {
        let p = store.profile
        return "\(p.sex.title) · \(p.age) · \(Int(p.heightCm)) cm · \(String(format: "%.1f", p.weightKg)) kg"
    }

    private var targetsDetail: String {
        "\(Format.duration(store.targets.sleepNeedHours * 60)) sleep · \(Int(store.targets.steps).formatted()) steps"
    }
}

/// One row of the Settings list: a symbol, a title and what's set now.
struct SettingsRow: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .background(Theme.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The settings pages share one look.
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Sources

extension DataSource {
    /// Signs in, or asks for Apple Health access.
    @MainActor func connect() async throws {
        switch self {
        case .google: try await GoogleAuth.shared.connect()
        case .appleHealth:
            try await HealthKitClient.connect()
            HealthKitClient.startBackgroundDelivery { await HealthStore.syncAnywhere() }
        case .whoop: try await WhoopAuth.shared.connect()
        }
    }

    @MainActor func disconnect() {
        switch self {
        case .google: GoogleAuth.shared.disconnect()
        case .appleHealth: HealthKitClient.disconnect()
        case .whoop: WhoopAuth.shared.disconnect()
        }
    }

    /// Why this source can't be connected on this iPhone or in this build, if it can't.
    @MainActor var unavailableReason: String? {
        switch self {
        case .appleHealth where !HealthKitClient.isAvailable: return "Apple Health isn't available on this device."
        case .whoop where !WhoopAuth.shared.isConfigured: return "Whoop sign-in isn't set up in this build yet."
        default: return nil
        }
    }

    var connectTitle: String {
        switch self {
        case .google: return "Connect Fitbit"
        case .appleHealth: return "Connect Apple Health"
        case .whoop: return "Connect Whoop"
        }
    }

    /// The source as people know it, for the welcome screens.
    var shortTitle: String {
        switch self {
        case .google: return "Google Health"
        case .appleHealth: return "Apple Watch"
        case .whoop: return "Whoop"
        }
    }

    var symbol: String {
        switch self {
        case .google: return "heart.text.square"
        case .appleHealth: return "applewatch"
        case .whoop: return "circle.dashed"
        }
    }
}

struct SourcesSettings: View {
    @EnvironmentObject private var store: HealthStore
    @ObservedObject private var auth = GoogleAuth.shared
    @State private var connecting = false
    @State private var error: String?
    @AppStorage(WhoopClient.appleHealthKey) private var whoopUsesAppleHealth = false

    var body: some View {
        SettingsPage(title: "Sources") {
            Section {
                Picker("Source", selection: Binding(get: { store.source }, set: { new in
                    error = nil
                    Task { await store.switchSource(new) }
                })) {
                    ForEach(DataSource.allCases) { Text($0.title).tag($0) }
                }
                if store.source.isConnected {
                    Label("\(store.source.title) connected", systemImage: "checkmark.circle.fill")
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
                        store.source.disconnect()
                        Task { await store.accountChanged() }
                    }
                } else if let reason = store.source.unavailableReason {
                    Text(reason).foregroundStyle(Theme.secondary)
                } else {
                    Button {
                        connecting = true
                        error = nil
                        Task {
                            do {
                                try await store.source.connect()
                                await store.accountChanged()
                            } catch {
                                self.error = error.localizedDescription
                            }
                            connecting = false
                        }
                    } label: {
                        HStack {
                            Label(store.source.connectTitle, systemImage: "link")
                            Spacer()
                            if connecting { ProgressView() }
                        }
                    }
                    .disabled(connecting)
                }
                if let message = error ?? store.lastError {
                    Text(message).font(.footnote).foregroundStyle(Theme.accent)
                }
            } footer: {
                Text(footer)
            }
            .listRowBackground(Theme.card)

            if store.source == .whoop && store.source.isConnected && HealthKitClient.isAvailable {
                Section {
                    // Whoop shares no heart rate through its API, but writes it to Apple Health.
                    Toggle("Use Apple Health too", isOn: Binding(get: { whoopUsesAppleHealth }, set: { on in
                        Task {
                            if on {
                                do { try await HealthKitClient.connectForWhoop() } catch {
                                    self.error = error.localizedDescription
                                    return
                                }
                            }
                            whoopUsesAppleHealth = on
                            await store.sync()
                        }
                    }))
                } footer: {
                    Text("Reads the heart rate Whoop writes to Apple Health (for the sleep and heart zone graphs) and this iPhone's steps for days the band wasn't worn. In the Whoop app, turn on Apple Health under Settings › Integrations.")
                }
                .listRowBackground(Theme.card)
            }

            if store.source.isConnected, !store.syncReport.isEmpty {
                Section("What the last sync found") {
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
                .listRowBackground(Theme.card)
            }
        }
    }

    private var footer: String {
        let switching = " Changing source starts your 30-day baselines again: bands measure things differently, HRV above all."
        switch (store.source, store.source.isConnected) {
        case (.google, true):
            return "Halo reads sleep, heart, activity, vitals and weight from your Fitbit through Google Health." + switching
        case (.google, false):
            return "For Fitbit and Pixel Watch. Sign in with the Google account your Fitbit uses. Until then Halo shows sample data."
        case (.appleHealth, true):
            return "Halo reads sleep, heart, activity, vitals, workouts and weight from Apple Health. To change what it can read, open the Health app › your profile › Apps › Halo." + switching
        case (.appleHealth, false):
            return "For \(DataSource.appleHealth.devices). Until you connect, Halo shows sample data."
        case (.whoop, true):
            return "Halo reads recovery, sleep, workouts, steps, calories and weight from Whoop, keeps every record on this iPhone and reads only what's new. Recovery and sleep are Whoop's own scores, and each night's sleep need is the one Whoop worked out, so the numbers match the Whoop app. Whoop's days are filed under the day you woke up. Cardio load comes from each workout's time in Whoop's zones, worked out as the same heart rate would be on a Fitbit, plus everyday movement from the day's strain. Sleep shows stage totals without the timeline." + switching
        case (.whoop, false):
            return "Sign in with your Whoop account. Until then Halo shows sample data."
        }
    }
}

// MARK: About you

/// Sex, age, height and weight: the rows themselves, for Settings and the welcome screens.
struct AboutYouFields: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        Picker("Sex", selection: $store.profile.sex) {
            ForEach(Profile.Sex.allCases) { Text($0.title).tag($0) }
        }
        Stepper(value: $store.profile.birthYear, in: 1930...2012) {
            SettingsValue(title: "Born", value: String(store.profile.birthYear))
        }
        Stepper(value: $store.profile.heightCm, in: 120...220, step: 1) {
            SettingsValue(title: "Height", value: "\(Int(store.profile.heightCm)) cm")
        }
        Stepper(value: $store.profile.weightKg, in: 35...200, step: 0.5) {
            SettingsValue(title: "Weight", value: String(format: "%.1f kg", store.profile.weightKg))
        }
    }
}

struct AboutYouSettings: View {
    var body: some View {
        SettingsPage(title: "About you") {
            Section {
                AboutYouFields()
            } footer: {
                Text("Used for your resting calories and the top of your heart-rate zones (your maximum heart rate comes from your age). A connected scale overrides the weight.")
            }
            .listRowBackground(Theme.card)
        }
    }
}

// MARK: Targets

/// Sleep, steps, zone minutes, cardio focus and the first day of the week.
struct TargetsFields: View {
    @EnvironmentObject private var store: HealthStore
    @AppStorage(WeekStart.key) private var weekStartsOnMonday = WeekStart.startsOnMonday

    var body: some View {
        Stepper(value: $store.targets.sleepNeedHours, in: 6...10, step: 0.25) {
            SettingsValue(title: "Sleep need", value: Format.duration(store.targets.sleepNeedHours * 60))
        }
        Stepper(value: $store.targets.steps, in: 2_000...25_000, step: 500) {
            SettingsValue(title: "Steps", value: Int(store.targets.steps).formatted())
        }
        Stepper(value: $store.targets.zoneMinutes, in: 10...120, step: 5) {
            SettingsValue(title: "Active minutes", value: "\(Int(store.targets.zoneMinutes)) a day")
        }
        Picker("Cardio focus", selection: $store.targets.cardioFocus) {
            ForEach(CardioFocus.allCases) { Text($0.title).tag($0) }
        }
        Picker("Week starts on", selection: $weekStartsOnMonday) {
            Text("Monday").tag(true)
            Text("Sunday").tag(false)
        }
        .onChange(of: weekStartsOnMonday) { _, _ in store.refreshScores() }
    }
}

struct TargetsSettings: View {
    @EnvironmentObject private var store: HealthStore

    var body: some View {
        SettingsPage(title: "Health targets") {
            Section {
                TargetsFields()
            } footer: {
                let week = store.cardioWeek(endingOn: .now)
                Text("\(store.targets.cardioFocus.detail) This week: \(week.focus.title), a cardio load of \(Int(week.target)).")
            }
            .listRowBackground(Theme.card)
        }
    }
}

struct SettingsValue: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).font(Theme.number(16, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: Appearance

/// Halo's color sets, side by side; tap one to use it.
struct ColorSetsStrip: View {
    @EnvironmentObject private var look: AppearanceStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
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
                    .accessibilityLabel("\(p.name) colors")
                    .accessibilityAddTraits(look.appearance.presetID == p.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject private var look: AppearanceStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsPage(title: "Appearance") {
            Section {
                Picker("Mode", selection: $look.appearance.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 16) {
                    Ring(progress: 0.82, lineWidth: 5).frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("82").font(Theme.number(30)).foregroundStyle(Theme.ink)
                        Text("Preview").haloLabel()
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } header: {
                Text("Look")
            } footer: {
                Text("The color sets and Reset are on the main Settings page.")
            }
            .listRowBackground(Theme.card)

            Section {
                ColorPicker("Main color", selection: colorBinding(\.ink), supportsOpacity: false)
                ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
                ColorPicker("Background", selection: colorBinding(\.background), supportsOpacity: false)
                ColorPicker("Cards", selection: colorBinding(\.card), supportsOpacity: false)
                Toggle("Same colors in Light and Dark", isOn: $look.appearance.sameInBoth)
            } header: {
                Text("Custom colors")
            } footer: {
                Text("Colors you pick here are for \(look.appearance.sameInBoth ? "both Light and Dark mode" : (scheme == .dark ? "Dark mode" : "Light mode")).")
            }
            .listRowBackground(Theme.card)
        }
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
}

// MARK: How the scores work

struct ScoresExplainer: View {
    var body: some View {
        SettingsPage(title: "How the scores work") {
            Section {
                explainer("Recovery", "Set each morning: HRV (counts most) and resting heart rate against your last 30 days, in your own usual spread, so a normal morning is about 67; then last night's sleep is a quarter of it.")
                explainer("Effort", "Today only, from zero at midnight. Half is steps against your step target. Half is active minutes (time in your heart-rate zones) against your daily target: a moderate minute counts a quarter, a cardio minute twice, a peak minute three times.")
                explainer("Cardio load", "How hard your heart worked this week. Halo looks at your heart rate minute by minute against your resting and maximum heart rate. Resting adds nothing and neither do brief spikes; a brisk walk adds a little, and time that lasts adds more the higher you go (about 1 a minute in moderate, 2 in cardio, 3 in peak). The weekly target follows your last four weeks and is never below 210: Maintain keeps it level, Build adds 10%, Recover lowers it when your recovery is low or you've done much more than usual.")
                explainer("Sleep", "Time asleep against your need, deep and REM share, efficiency, how little you woke and a steady bedtime. Curved so only a near-perfect night reaches the 90s.")
                explainer("Balance", "Six spokes for the week: sleep, HRV level and steadiness, recovery, steps, weekly cardio load and resting heart rate.")
            }
            .listRowBackground(Theme.card)
        }
    }

    private func explainer(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 2)
    }
}
