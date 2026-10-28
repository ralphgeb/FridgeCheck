import BackgroundTasks
import SwiftUI

@main
struct HaloApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = HealthStore()
    @StateObject private var look = AppearanceStore()
    private static let refreshID = "com.ralphgeb.halo.refresh"

    init() {
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
                if (store.lastSync?.timeIntervalSinceNow ?? -.infinity) < -2 * 60 {
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
        // while the app is open, pick up new readings every few minutes
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4 * 60))
                if scenePhase == .active { await store.sync() }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView { onboarded = true }
                .environmentObject(store)
                .environmentObject(look)
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
