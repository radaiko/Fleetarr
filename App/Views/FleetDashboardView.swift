import SwiftUI
import FleetarrKit

/// The Fleet home screen (spec §5): a slim health header (the thesis — "is everything OK?") over a
/// responsive grid of compact instance cards, ordered so anything needing attention floats to the
/// top. Pull-to-refresh, plus auto-refresh that pauses when backgrounded.
struct FleetDashboardView: View {
    @Environment(FleetStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("refreshIntervalSeconds") private var refreshInterval: Double = 60
    @State private var showingSettings = false

    private let columns = [GridItem(.adaptive(minimum: 285, maximum: 440), spacing: 12)]

    var body: some View {
        ScrollView {
            if store.dashboardInstances.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    summaryHeader
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sortedInstances) { instance in
                            NavigationLink {
                                InstanceDetailView(instance: instance)
                            } label: {
                                InstanceCardView(
                                    instance: instance,
                                    status: store.status(for: instance),
                                    configured: store.hasStoredSecret(for: instance)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationDestination(isPresented: $showingSettings) {
            SettingsView()
        }
        .refreshable { await store.refresh() }
        // Auto-refresh; restarts on scene-phase change and only runs while active (pauses in the
        // background, spec §5).
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(max(15, refreshInterval)))
            }
        }
    }

    // MARK: Header (the thesis)

    private var summaryHeader: some View {
        let summary = store.summary
        let clear = summary.problemBadgeCount == 0
        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(clear ? Color.green : summary.worstHealth.tint)
                .frame(width: 9, height: 9)
            Text(clear ? "All clear" : "^[\(summary.problemBadgeCount) problem](inflect: true)")
                .font(.title2.weight(.semibold))
            if summary.unreachableCount > 0 {
                Text("· ^[\(summary.unreachableCount) unreachable](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("^[\(store.dashboardInstances.count) service](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = store.lastRefresh {
                    Text("updated \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Ordering — attention first

    private var sortedInstances: [FleetInstance] {
        store.dashboardInstances.sorted { lhs, rhs in
            let a = attentionScore(lhs), b = attentionScore(rhs)
            if a != b { return a > b }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    private func attentionScore(_ instance: FleetInstance) -> Int {
        let configured = store.hasStoredSecret(for: instance)
        let health = configured ? (store.status(for: instance)?.health ?? .unknown) : .unknown
        let badge = store.status(for: instance)?.badgeCount ?? 0
        // Higher = more attention. Warning/error/unreachable outrank healthy; badge count breaks ties.
        return health.severityRank * 1000 + badge
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No services yet", systemImage: "square.grid.2x2")
        } description: {
            Text("Add your Sonarr, Radarr, SABnzbd, Plex and other instances in Settings to see them here.")
        }
        .padding(.top, 60)
    }
}
