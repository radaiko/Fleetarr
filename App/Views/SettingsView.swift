import SwiftUI
import FleetarrKit

/// Settings area (spec §8): instance management plus the iCloud-sync and analytics disclosures and
/// opt-outs (spec §3.4 / §3.5).
struct SettingsView: View {
    @Environment(FleetStore.self) private var store
    @AppStorage("syncEnabled") private var syncEnabled = true
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    @State private var showingAdd = false
    @State private var editingInstance: FleetInstance?

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
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Instance", systemImage: "plus")
                }
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
