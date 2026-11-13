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
                // A sync only asks for what's new, so it's cheap: catch up every time the app opens
                Task {
                    await store.sync()
                    await compare.syncIfDue(main: store)
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
            // The iPhone Duo's outside screen is nearly as wide as it's tall: the tabs stand up in
            // the right-hand column, under the clock and camera. Opened up, it's the same, with
            // each page's cards in two columns across the wide screen.
            GeometryReader { g in
                // two columns only where each still gets a phone's width (the open Duo held
                // sideways); upright, the open Duo shows one roomy column
                let columns = g.size.width >= 760
                let short = g.size.height / max(g.size.width, 1) < 1.6
                // upright and open, iOS's status bar runs across the top: pages go up into it
                let band = g.size.height > g.size.width && g.safeAreaInsets.top > 30
                    && g.safeAreaInsets.trailing <= 40 ? g.safeAreaInsets.top : 0
                Group {
                    if columns || short {
                        railed(statusColumn: g.safeAreaInsets.trailing)
                            .environment(\.wideLayout, columns)
                            .environment(\.statusBand, band)
                    } else {
                        tabs
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        // the screen changed size (folded or opened): only the big one turns sideways
        .onChange(of: wide) { _, _ in HaloAppDelegate.refreshOrientations() }
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
                if scenePhase == .active {
                    await store.sync()
                    // testing: Compare keeps every band up to date too
                    await compare.syncIfDue(main: store)
                }
            }
        }
        // screenshots in the simulator start on the tab they're of (-haloTab 0…3)
        .onAppear {
            if Distribution.isScreenshots { tab = min(3, max(0, UserDefaults.standard.integer(forKey: "haloTab"))) }
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


    /// The iPhone Duo, closed or open: one page at a time, the four tabs stacked at the bottom of
    /// the right-hand column, under the clock, camera and battery. Where iOS keeps that column
    /// for itself (the status column), the tabs sit in it, lined up with the battery.
    private func railed(statusColumn: CGFloat) -> some View {
        let inColumn = statusColumn > 40
        let column = inColumn ? statusColumn : 78
        return HStack(spacing: 0) {
            ZStack {
                switch tab {
                case 1: FitnessView(showSettings: $showSettings).environment(\.tabReselect, reselects[1])
                case 2: HealthView(showSettings: $showSettings).environment(\.tabReselect, reselects[2])
                case 3: SleepView(showSettings: $showSettings).environment(\.tabReselect, reselects[3])
                default: TodayView(showSettings: $showSettings).environment(\.tabReselect, reselects[0])
                }
            }
            .frame(maxWidth: .infinity)
            if !inColumn { Color.clear.frame(width: column) }
        }
        .overlay(alignment: .bottomTrailing) {
            DuoRail(tabs: [0, 1, 2, 3], selection: Binding(get: { tab }, set: { new in
                if new == tab { reselects[new] += 1 }
                tab = new
            }))
            .frame(width: column)
            .offset(x: inColumn ? column : 0)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

/// The tabs standing up, for the iPhone Duo: a slim column on the right, its top left clear for
/// the clock, camera and battery, the tabs stacked in its bottom corner within reach of the thumb.
struct DuoRail: View {
    let tabs: [Int]
    @Binding var selection: Int

    private struct Item {
        let title: String
        let symbol: String
        let selectedSymbol: String
    }
    private static let all: [Int: Item] = [
        0: Item(title: "Today", symbol: "circle.circle", selectedSymbol: "circle.circle.fill"),
        1: Item(title: "Fitness", symbol: "figure.run", selectedSymbol: "figure.run"),
        2: Item(title: "Health", symbol: "waveform.path.ecg", selectedSymbol: "waveform.path.ecg"),
        3: Item(title: "Sleep", symbol: "moon", selectedSymbol: "moon.fill"),
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tag in
                if let item = Self.all[tag] {
                    let on = selection == tag
                    Button { selection = tag } label: {
                        VStack(spacing: 3) {
                            Image(systemName: on ? item.selectedSymbol : item.symbol)
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .background(on ? Theme.ink : .clear, in: Circle())
                                .foregroundStyle(on ? Theme.background : Theme.text)
                            Text(item.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(on ? Theme.text : Theme.secondary)
                        }
                        .frame(width: 62, height: 70)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 7)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .bottom)
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
