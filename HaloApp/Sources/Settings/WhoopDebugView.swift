import SwiftUI

/// Whoop's raw answers, for finding out why a sync comes back short: the newest records of each
/// kind with no dates asked for, the account and body, and the same through Whoop's older API to
/// compare. Copy sends it all to the clipboard to paste into a message.
struct WhoopDebugView: View {
    @EnvironmentObject private var store: HealthStore
    @State private var output = ""
    @State private var running = false

    private let checks: [(title: String, path: String, version: String)] = [
        ("Newest cycles", "cycle?limit=5", "v2"),
        ("Newest sleep", "activity/sleep?limit=5", "v2"),
        ("Newest recovery", "recovery?limit=5", "v2"),
        ("Newest workouts", "activity/workout?limit=5", "v2"),
        ("Account", "user/profile/basic", "v2"),
        ("Body", "user/measurement/body", "v2"),
        ("Newest cycles (older API)", "cycle?limit=5", "v1"),
    ]

    var body: some View {
        List {
            Section {
                Button {
                    run()
                } label: {
                    HStack {
                        Label("Ask Whoop", systemImage: "arrow.down.circle")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running || store.source != .whoop || !store.source.isConnected)
                Button {
                    UIPasteboard.general.string = output
                } label: {
                    Label("Copy everything", systemImage: "doc.on.doc")
                }
                .disabled(output.isEmpty)
            } footer: {
                Text("Asks Whoop for the newest records of each kind, with no dates, and shows exactly what comes back. If the newest records are from months ago, Whoop isn't sharing your recent data with apps like Halo.")
            }
            .listRowBackground(Theme.card)

            if !output.isEmpty {
                Section("What Whoop sent") {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Whoop debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        running = true
        output = ""
        let client = WhoopClient(token: { try await WhoopAuth.shared.accessToken() }, restingKcalPerDay: store.profile.restingCalories())
        Task {
            var parts = ["Halo · \(Date().formatted(.iso8601))"]
            for c in checks {
                parts.append("── \(c.title) ──\n" + (await client.raw(c.path, version: c.version)))
                output = parts.joined(separator: "\n\n")
            }
            running = false
        }
    }
}
