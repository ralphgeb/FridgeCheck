import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: HealthStore
    @ObservedObject private var auth = GoogleAuth.shared
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                targetsSection
                Section("How the scores work") {
                    explainer("Recovery", "HRV and resting heart rate against your 30-day baseline, plus last night's sleep.")
                    explainer("Effort", "Active Zone Minutes and steps against your targets.")
                    explainer("Sleep", "Time asleep against your need, deep and REM share, efficiency and a steady bedtime.")
                }
                Section {
                } footer: {
                    Text("Halo reads your data with read-only access and keeps it on this iPhone. Halo isn't a medical device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .tint(Theme.ink)
        }
    }

    private var accountSection: some View {
        Section {
            if auth.isConnected {
                Label("Fitbit connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.ink)
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
        } header: {
            Text("Data")
        } footer: {
            Text(auth.isConnected
                 ? "Halo reads sleep, heart, activity and vitals from your Fitbit through Google Health."
                 : "Fitbit data now lives in your Google account. Sign in with the Google account your Fitbit uses. Until then Halo shows sample data.")
        }
    }

    private var targetsSection: some View {
        Section("Targets") {
            Stepper(value: $store.targets.sleepNeedHours, in: 6...10, step: 0.25) {
                row("Sleep need", Format.duration(store.targets.sleepNeedHours * 60))
            }
            Stepper(value: $store.targets.activeZoneMinutes, in: 10...120, step: 5) {
                row("Active Zone Minutes", "\(Int(store.targets.activeZoneMinutes))")
            }
            Stepper(value: $store.targets.steps, in: 2_000...25_000, step: 500) {
                row("Steps", Int(store.targets.steps).formatted())
            }
        }
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
    }
}
