import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct HaloApp: App {
    @UIApplicationDelegateAdaptor(HaloAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = HealthStore()
    @StateObject private var look = AppearanceStore()
    @StateObject private var compare = CompareStore()   // testing only: the Compare tab
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
        // tapping a morning or evening note opens its page
        UNUserNotificationCenter.current().delegate = NotificationOpener.shared
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
                .environmentObject(compare)
                .preferredColorScheme(look.appearance.mode.colorScheme)
                .onAppear { HealthStore.foreground = store }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.reloadIfUpdatedElsewhere()
                // A sync only asks for what's new, so it's cheap: catch up whenever the app opens
                if store.showingSample || store.days.isEmpty || (store.lastSync?.timeIntervalSinceNow ?? -.infinity) < -2 * 60 {
                    Task {
                        await store.sync()
                        await compare.syncIfDue(main: store)
                    }
                } else {
                    Task { await compare.syncIfDue(main: store) }
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
    @EnvironmentObject private var compare: CompareStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var tab = 0
    /// Taps on each tab while it was already showing: the page scrolls up, then goes to today.
    @State private var reselects = [0, 0, 0, 0]
    /// The welcome screens show once, the first time Halo opens.
    @AppStorage("onboarded") private var onboarded = false
    /// Wide (the iPhone Duo opened up): Today on the left, the other pages on the right.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The page on the right when wide: Fitness, Health or Sleep.
    @State private var sideTab = 1
    private var wide: Bool { sizeClass == .regular }

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
        Group {
            if wide { duo } else { tabs }
        }
        // the screen changed size (folded or opened): only the big one turns sideways
        .onChange(of: wide) { _, isWide in
            if isWide, tab != 0 { sideTab = tab }
            if !isWide { tab = sideTab }
            HaloAppDelegate.refreshOrientations()
        }
        // Colors are read when views draw, so a new look rebuilds the pages (the sheet stays open).
        .id(look.appearance)
        .environment(\.openSettings, { showSettings = true })
        .tint(Theme.ink)
        .sensoryFeedback(.selection, trigger: tab)
        .sensoryFeedback(.selection, trigger: sideTab)
        // while the app is open, pick up new readings every few minutes; until your own data has
        // come in (just connected, or a sync that failed), keep trying every 20 seconds
        .task {
            while !Task.isCancelled {
                let waiting = store.source.isConnected && (store.showingSample || store.days.isEmpty || store.lastError != nil)
                try? await Task.sleep(for: .seconds(waiting ? 20 : 4 * 60))
                if scenePhase == .active {
                    await store.sync()
                    // testing: Compare keeps every band up to date too
                    await compare.syncIfDue(main: store)
                }
            }
        }
        // Halo Plus bought through the App Store: check it's still active, and hear about renewals
        .task { await PlusPurchase.refresh() }
        .task { await PlusPurchase.listen() }
        .sheet(isPresented: $store.showPlus) {
            PlusSheet(reason: "Earlier days are part of Halo Plus.")
                .environmentObject(store)
                .preferredColorScheme(look.appearance.mode.colorScheme)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(look)
                .environmentObject(compare)
                .preferredColorScheme(look.appearance.mode.colorScheme)
        }
        .onOpenURL { url in
            // Widget taps open a specific page: halo://today, halo://fitness, halo://health, halo://sleep,
            // and a place inside it (halo://sleep/bank, halo://today/zones)
            store.deepLink = url.path.isEmpty || url.path == "/" ? nil : url.path
            switch url.host {
            case "fitness": tab = 1
            case "health": tab = 2
            case "sleep": tab = 3
            default: tab = 0
            }
            if tab != 0 { sideTab = tab }
        }
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { tab }, set: { new in
            if new == tab, reselects.indices.contains(new) { reselects[new] += 1 }
            tab = new
        })) {
            TodayView(showSettings: $showSettings)
                .environment(\.tabReselect, reselects[0])
                .tabItem { Label("Today", systemImage: "circle.circle") }
                .tag(0)
            FitnessView(showSettings: $showSettings)
                .environment(\.tabReselect, reselects[1])
                .tabItem { Label("Fitness", systemImage: "figure.run") }
                .tag(1)
            HealthView(showSettings: $showSettings)
                .environment(\.tabReselect, reselects[2])
                .tabItem { Label("Health", systemImage: "waveform.path.ecg") }
                .tag(2)
            SleepView(showSettings: $showSettings)
                .environment(\.tabReselect, reselects[3])
                .tabItem { Label("Sleep", systemImage: "moon") }
                .tag(3)
        }
    }


    /// Open on the iPhone Duo: Today always on the left, Fitness, Health or Sleep on the right,
    /// and the tabs as a slim rail down the right edge, under the clock and camera.
    private var duo: some View {
        HStack(spacing: 0) {
            TodayView(showSettings: $showSettings)
                .environment(\.tabReselect, reselects[0])
                .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.hairline).frame(width: 0.5).ignoresSafeArea()
            ZStack {
                switch sideTab {
                case 2: HealthView(showSettings: $showSettings).environment(\.tabReselect, reselects[2])
                case 3: SleepView(showSettings: $showSettings).environment(\.tabReselect, reselects[3])
                default: FitnessView(showSettings: $showSettings).environment(\.tabReselect, reselects[1])
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: sideTab)
            DuoRail(selection: Binding(get: { sideTab }, set: { new in
                if new == sideTab { reselects[new] += 1 }
                sideTab = new
            }))
        }
        .background(Theme.background.ignoresSafeArea())
    }

}

/// The tabs standing up, for the iPhone Duo's open screen: Fitness, Health and Sleep in a slim
/// column down the right edge, starting under the clock and camera.
struct DuoRail: View {
    @Binding var selection: Int
    private struct Item: Identifiable {
        let id: Int
        let title: String
        let symbol: String
        let selectedSymbol: String
    }
    private let items = [Item(id: 1, title: "Fitness", symbol: "figure.run", selectedSymbol: "figure.run"),
                         Item(id: 2, title: "Health", symbol: "waveform.path.ecg", selectedSymbol: "waveform.path.ecg"),
                         Item(id: 3, title: "Sleep", symbol: "moon", selectedSymbol: "moon.fill")]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items) { item in
                let tag = item.id, title = item.title
                Button { selection = tag } label: {
                    VStack(spacing: 4) {
                        Image(systemName: selection == tag ? item.selectedSymbol : item.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(selection == tag ? Theme.ink : .clear, in: Circle())
                            .foregroundStyle(selection == tag ? Theme.background : Theme.secondary)
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selection == tag ? Theme.text : Theme.secondary)
                    }
                    .frame(width: 64, height: 70)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(selection == tag ? .isSelected : [])
            }
        }
        .padding(.vertical, 10)
        .background(Theme.card, in: Capsule())
        .padding(.top, 12)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.25), value: selection)
    }
}

/// Portrait on an ordinary iPhone; any way round on a big screen (the iPhone Duo opened up),
/// so Halo fills it instead of sitting in a phone-sized box.
final class HaloAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.isBigScreen(window?.windowScene) ? .all : .portrait
    }

    static func isBigScreen(_ scene: UIWindowScene?) -> Bool {
        guard let scene else { return false }
        let b = scene.screen.bounds
        return min(b.width, b.height) >= 560
    }

    /// Asks iOS to look again after the screen changes (folding or opening).
    @MainActor static func refreshOrientations() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !isBigScreen(scene) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}
