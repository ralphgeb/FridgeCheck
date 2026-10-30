import BackgroundTasks
import SwiftUI

@main
struct HaloApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = HealthStore()
    @StateObject private var look = AppearanceStore()
    private static let refreshID = "com.ralphgeb.halo.refresh"

    init() {
        // iOS keeps the keychain when an app is deleted, so a reinstall could look signed in with
        // sign-ins that no longer work. A fresh install starts signed out and signs in on the
        // welcome screens.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "installed") {
            defaults.set(true, forKey: "installed")
            if !defaults.bool(forKey: "onboarded") {
                MainActor.assumeIsolated {
                    GoogleAuth.shared.disconnect()
                    WhoopAuth.shared.disconnect()
                }
            }
        }
        // iOS wakes the app in the background now and then; each time Halo syncs and refreshes the widgets.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.scheduleRefresh()
            let work = Task { @MainActor in
                await HealthStore.syncAnywhere()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        // Apple Health tells Halo when new data lands (even with the app closed), so it can sync then
        Task { @MainActor in
            if DataSource.current == .appleHealth, HealthKitClient.isConnected {
                HealthKitClient.startBackgroundDelivery { await HealthStore.syncAnywhere() }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(look)
                .preferredColorScheme(look.appearance.mode.colorScheme)
                .onAppear { HealthStore.foreground = store }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.reloadIfUpdatedElsewhere()
                // A sync only asks for what's new, so it's cheap: catch up whenever the app opens
                if store.showingSample || store.days.isEmpty || (store.lastSync?.timeIntervalSinceNow ?? -.infinity) < -2 * 60 {
                    Task { await store.sync() }
                }
            case .background:
                Self.scheduleRefresh()
            default:
                break
            }
        }
    }

    /// Asks iOS to wake Halo in the background every 15 minutes or so. iOS decides when it really
    /// does (more often for apps you open a lot, less on low battery).
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct RootView: View {
    @EnvironmentObject private var store: HealthStore
    @EnvironmentObject private var look: AppearanceStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var tab = 0
    /// The welcome screens show once, the first time Halo opens.
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        // The first time, the welcome screens are all there is (on the same plain background as the
        // launch screen), so the app never shows behind them; then the app fades in.
        ZStack {
            if onboarded {
                app.transition(.opacity)
            } else {
                OnboardingView {
                    onboarded = true
                    Task { await store.sync() }
                }
                .transition(.opacity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.4), value: onboarded)
    }

    private var app: some View {
        TabView(selection: $tab) {
            TodayView(showSettings: $showSettings)
                .tabItem { Label("Today", systemImage: "circle.circle") }
                .tag(0)
            FitnessView(showSettings: $showSettings)
                .tabItem { Label("Fitness", systemImage: "figure.run") }
                .tag(1)
            HealthView(showSettings: $showSettings)
                .tabItem { Label("Health", systemImage: "waveform.path.ecg") }
                .tag(2)
            SleepView(showSettings: $showSettings)
                .tabItem { Label("Sleep", systemImage: "moon") }
                .tag(3)
        }
        // Colors are read when views draw, so a new look rebuilds the pages (the sheet stays open).
        .id(look.appearance)
        .environment(\.openSettings, { showSettings = true })
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: tab)
        // while the app is open, pick up new readings every few minutes; until your own data has
        // come in (just connected, or a sync that failed), keep trying every 20 seconds
        .task {
            while !Task.isCancelled {
                let waiting = store.source.isConnected && (store.showingSample || store.days.isEmpty || store.lastError != nil)
                try? await Task.sleep(for: .seconds(waiting ? 20 : 4 * 60))
                if scenePhase == .active { await store.sync() }
            }
        }
        .sheet(isPresented: $store.showPlus) {
            PlusSheet(reason: "Earlier days are part of Halo Plus.")
                .environmentObject(store)
                .preferredColorScheme(look.appearance.mode.colorScheme)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(look)
                .preferredColorScheme(look.appearance.mode.colorScheme)
        }
        .onOpenURL { url in
            // Widget taps open a specific page: halo://today, halo://fitness, halo://health, halo://sleep
            switch url.host {
            case "fitness": tab = 1
            case "health": tab = 2
            case "sleep": tab = 3
            default: tab = 0
            }
        }
    }
}
