import SwiftUI
import FleetarrKit

/// The Fleet home screen (spec §5): a health hero that answers "is everything OK?" at a glance, over
/// attention-grouped instance cards — anything troubled floats into a "Needs attention" section on
/// top. Pull-to-refresh, plus auto-refresh that pauses when backgrounded.
struct FleetDashboardView: View {
    @Environment(FleetStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("refreshIntervalSeconds") private var refreshInterval: Double = 60
    @State private var showingSettings = false

    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 460), spacing: 12)]

    var body: some View {
        ScrollView {
            if store.dashboardInstances.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    FleetHealthHeader(
                        summary: store.summary,
                        serviceCount: store.dashboardInstances.count,
                        attentionCount: troubledInstances.count,
                        lastRefresh: store.lastRefresh,
                        isRefreshing: store.isRefreshing
                    )
                    if troubledInstances.isEmpty {
                        grid(sortedInstances)
                    } else {
                        section("Needs attention", troubledInstances)
                        if !healthyInstances.isEmpty {
                            section("Everything else", healthyInstances)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .background(groupedBackground)
        .navigationTitle("Fleet")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

    // MARK: Sections

    private func section(_ title: String, _ items: [FleetInstance]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            grid(items)
        }
    }

    private func grid(_ items: [FleetInstance]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { instance in
                NavigationLink {
                    InstanceDetailView(instance: instance)
                } label: {
                    InstanceCardView(
                        instance: instance,
                        status: store.status(for: instance),
                        configured: store.hasStoredSecret(for: instance),
                        stale: store.isStale(instance),
                        lastUpdated: store.lastUpdated(for: instance)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Ordering — attention first

    private var sortedInstances: [FleetInstance] {
        store.dashboardInstances.sorted { lhs, rhs in
            let a = attentionScore(lhs), b = attentionScore(rhs)
            if a != b { return a > b }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    private var troubledInstances: [FleetInstance] { sortedInstances.filter(isTroubled) }
    private var healthyInstances: [FleetInstance] { sortedInstances.filter { !isTroubled($0) } }

    private func isTroubled(_ instance: FleetInstance) -> Bool {
        guard store.hasStoredSecret(for: instance) else { return true }
        if store.isStale(instance) { return true }
        return (store.status(for: instance)?.health ?? .unknown).isProblem
    }

    private func attentionScore(_ instance: FleetInstance) -> Int {
        let configured = store.hasStoredSecret(for: instance)
        // Higher = more attention. Unconfigured sits just above healthy so it's visible but not
        // alarming; a stale/offline tile ranks like unreachable; real problems outrank the rest;
        // badge count breaks ties.
        guard configured else { return (HealthState.healthy.severityRank + 1) * 1000 }
        if store.isStale(instance) { return HealthState.unreachable.severityRank * 1000 }
        let health = store.status(for: instance)?.health ?? .unknown
        let badge = store.status(for: instance)?.badgeCount ?? 0
        return health.severityRank * 1000 + badge
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No services yet", systemImage: "square.stack.3d.up")
        } description: {
            Text("Add your Sonarr, Radarr, SABnzbd, Plex and other instances to watch their health here.")
        } actions: {
            Button("Add a service") { showingSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }

    private var groupedBackground: some ShapeStyle {
        #if os(iOS)
        return Color(.systemGroupedBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - Health hero (the thesis)

/// The dashboard's thesis: a glanceable verdict on the whole fleet. A soft status "orb" plus a bold
/// headline answer "is everything OK?" before the eye reaches any card.
private struct FleetHealthHeader: View {
    let summary: FleetSummary
    let serviceCount: Int
    let attentionCount: Int
    let lastRefresh: Date?
    let isRefreshing: Bool

    private var clear: Bool { attentionCount == 0 }
    private var tint: Color { clear ? .green : summary.worstHealth.tint }
    private var symbol: String { clear ? "checkmark.circle.fill" : summary.worstHealth.systemImageName }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: symbol)
                    .font(.system(size: 27, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 2) {
                Text(clear ? "All clear" : "Needs attention")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text(countLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let last = lastRefresh {
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            if isRefreshing { ProgressView() }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurface(cornerRadius: 24, tint: clear ? nil : tint))
        .accessibilityElement(children: .combine)
    }

    private var countLine: String {
        let services = "\(serviceCount) service\(serviceCount == 1 ? "" : "s")"
        return clear ? "\(services) · all healthy" : "\(services) · \(attentionCount) need attention"
    }
}
