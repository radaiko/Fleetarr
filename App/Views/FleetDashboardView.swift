import SwiftUI
import FleetarrKit

/// The Fleet home screen (spec §5): a combined problem summary, one tile per enabled instance with
/// a color+icon+text status glyph and headline metrics, pull-to-refresh, and auto-refresh that
/// pauses when the app is backgrounded.
struct FleetDashboardView: View {
    @Environment(FleetStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("refreshIntervalSeconds") private var refreshInterval: Double = 60

    var body: some View {
        List {
            if store.dashboardInstances.isEmpty {
                emptyState
            } else {
                summarySection
                ForEach(store.dashboardInstances) { instance in
                    Section {
                        NavigationLink {
                            InstanceDetailView(instance: instance)
                        } label: {
                            InstanceTileView(
                                instance: instance,
                                status: store.status(for: instance),
                                hasSecret: store.hasStoredSecret(for: instance)
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Fleet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
        .refreshable { await store.refresh() }
        // Auto-refresh loop; restarts when the scene phase changes and only runs while active,
        // so it pauses when backgrounded (spec §5).
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(max(15, refreshInterval)))
            }
        }
    }

    private var summarySection: some View {
        let summary = store.summary
        return Section {
            HStack(spacing: 12) {
                Image(systemName: summary.problemBadgeCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .imageScale(.large)
                    .foregroundStyle(summary.problemBadgeCount == 0 ? .green : summary.worstHealth.tint)
                VStack(alignment: .leading) {
                    Text(summary.problemBadgeCount == 0
                         ? "All clear"
                         : "^[\(summary.problemBadgeCount) problem](inflect: true) across the fleet")
                        .font(.headline)
                    if summary.unreachableCount > 0 {
                        Text("^[\(summary.unreachableCount) instance](inflect: true) unreachable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let last = store.lastRefresh {
                        Text("Updated \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isRefreshing {
                    ProgressView()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No services yet", systemImage: "square.grid.2x2")
        } description: {
            Text("Add your Sonarr, Radarr, SABnzbd, Plex and other instances in Settings to see them here.")
        }
    }
}
