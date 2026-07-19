import SwiftUI
import FleetarrKit

/// Settings area (spec §8): instance management plus the iCloud-sync and analytics disclosures and
/// opt-outs (spec §3.4 / §3.5).
struct SettingsView: View {
    @Environment(FleetStore.self) private var store
    @AppStorage("syncEnabled") private var syncEnabled = true
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("refreshIntervalSeconds") private var refreshInterval: Double = 60
    @AppStorage("upcomingLookaheadDays") private var lookaheadDays: Int = 7

    @State private var showingAdd = false
    @State private var editingInstance: FleetInstance?

    private let intervalOptions: [(String, Double)] = [
        ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
    ]

    var body: some View {
        List {
            Section("Instances") {
                if store.instances.isEmpty {
                    Text("No instances yet").foregroundStyle(.secondary)
                } else {
                    ForEach(store.instances) { instance in
                        Button {
                            editingInstance = instance
                        } label: {
                            InstanceRow(instance: instance, configured: store.hasStoredSecret(for: instance))
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteInstances)
                    .onMove { store.move(from: $0, to: $1) }
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Instance", systemImage: "plus")
                }
            }

            Section {
                Picker("Auto-refresh every", selection: $refreshInterval) {
                    ForEach(intervalOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
                Stepper("Calendar look-ahead: ^[\(lookaheadDays) day](inflect: true)",
                        value: $lookaheadDays, in: 1...30)
            } header: {
                Text("Dashboard")
            } footer: {
                Text("How often the fleet refreshes while open, and how far ahead Sonarr/Radarr "
                     + "Upcoming looks.")
            }

            Section {
                Toggle("Sync via iCloud", isOn: $syncEnabled)
            } header: {
                Text("Sync & privacy")
            } footer: {
                Text("Your instance list and dashboard layout sync across your devices via iCloud. "
                     + "API keys and tokens are end-to-end encrypted in iCloud Keychain. "
                     + "Changes to this setting take effect the next time you launch Fleetarr.")
            }

            Section {
                Toggle("Require Face ID / passcode", isOn: $appLockEnabled)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks Fleetarr when it moves to the background, since it can approve requests, "
                     + "remove downloads, and stop streams. This setting stays on this device.")
            }

            Section {
                Toggle("Anonymous usage analytics", isOn: $analyticsEnabled)
            } header: {
                Text("Analytics")
            } footer: {
                Text("Feature-usage and app-health events only — never media titles, usernames, or "
                     + "server addresses.")
            }

            Section {
                LabeledContent("Version", value: "0.1.0")
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .toolbar {
            if !store.instances.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        #endif
        .sheet(isPresented: $showingAdd) {
            InstanceEditView(mode: .add)
        }
        .sheet(item: $editingInstance) { instance in
            InstanceEditView(mode: .edit(instance))
        }
    }

    private func deleteInstances(_ offsets: IndexSet) {
        for index in offsets {
            store.delete(store.instances[index])
        }
    }
}

private struct InstanceRow: View {
    let instance: FleetInstance
    let configured: Bool

    var body: some View {
        HStack {
            Image(systemName: instance.serviceType.systemImageName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.label)
                Text(instance.baseURLString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !instance.isEnabled {
                Text("Disabled").font(.caption2).foregroundStyle(.secondary)
            } else if !configured {
                Image(systemName: "key.slash").foregroundStyle(.orange)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
