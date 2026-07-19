#if os(macOS)
import SwiftUI
import AppKit
import FleetarrKit

/// Content of the macOS menu-bar extra (spec §9.7): a glanceable fleet summary and per-instance
/// status without opening the main window.
struct MenuBarContent: View {
    @Environment(FleetStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                let summary = store.summary
                Image(systemName: summary.problemBadgeCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.problemBadgeCount == 0 ? .green : .orange)
                Text(summary.problemBadgeCount == 0
                     ? "All clear"
                     : "^[\(summary.problemBadgeCount) problem](inflect: true)")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
            }

            Divider()

            if store.dashboardInstances.isEmpty {
                Text("No instances configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.dashboardInstances) { instance in
                    row(for: instance)
                }
            }

            Divider()

            Button("Quit Fleetarr") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 300)
        .task { await store.refresh() }
    }

    private func row(for instance: FleetInstance) -> some View {
        let health = store.hasStoredSecret(for: instance) ? (store.status(for: instance)?.health ?? .unknown) : .unknown
        return HStack(spacing: 8) {
            Image(systemName: health.systemImageName)
                .foregroundStyle(health.tint)
            Text(instance.label)
            Spacer()
            if let line = store.status(for: instance)?.summaryLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(instance.label), \(health.displayLabel)")
    }
}
#endif
