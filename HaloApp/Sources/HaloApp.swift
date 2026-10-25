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
                await HealthStore().sync()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(look)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Fitbit syncs to Google every few minutes; don't ask more often than that.
                if (store.lastSync?.timeIntervalSinceNow ?? -.infinity) < -10 * 60 {
                    Task { await store.sync() }
                }
            case .background:
                Self.scheduleRefresh()
            default:
                break
            }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct RootView: View {
    @EnvironmentObject private var store: HealthStore
    @EnvironmentObject private var look: AppearanceStore
    @State private var showSettings = false
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TodayView(showSettings: $showSettings)
                .tabItem { Label("Today", systemImage: "circle.circle") }
                .tag(0)
            HealthView(showSettings: $showSettings)
                .tabItem { Label("Health", systemImage: "waveform.path.ecg") }
                .tag(1)
            SleepView(showSettings: $showSettings)
                .tabItem { Label("Sleep", systemImage: "moon") }
                .tag(2)
        }
        // Colors are read when views draw, so a new look rebuilds the pages (the sheet stays open).
        .id(look.appearance)
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: tab)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(look)
        }
        .onOpenURL { url in
            // Widget taps open a specific page: halo://today, halo://health, halo://sleep
            switch url.host {
            case "health": tab = 1
            case "sleep": tab = 2
            default: tab = 0
            }
        }
    }
}
