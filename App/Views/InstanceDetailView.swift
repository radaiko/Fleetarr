import SwiftUI
import FleetarrKit

/// Per-instance detail screen (spec §6, §8): current health, the problems list, the primary
/// activity list (queue/sessions/requests) with write actions (Phase 2), and a direct link to the
/// service's own web UI.
struct InstanceDetailView: View {
    @Environment(FleetStore.self) private var store
    @AppStorage("upcomingLookaheadDays") private var lookaheadDays: Int = 7
    let instance: FleetInstance

    @State private var service: (any FleetService)?
    @State private var activity: [ActivityItem] = []
    @State private var isLoading = false
    @State private var loadError: FleetError?
    @State private var pendingConfirmation: PendingAction?
    @State private var actionError: String?

    private var status: InstanceStatus? { store.status(for: instance) }
    private var configured: Bool { store.hasStoredSecret(for: instance) }

    var body: some View {
        List {
            headerSection
            problemsSection
            primaryActivitySection
            listingSections
            webUISection
        }
        .navigationTitle(instance.label)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if instance.serviceType.supportsDownloadControl {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { run { await store.setQueuePaused(true, on: instance) } } label: {
                            Label("Pause all downloads", systemImage: "pause.fill")
                        }
                        Button { run { await store.setQueuePaused(false, on: instance) } } label: {
                            Label("Resume all downloads", systemImage: "play.fill")
                        }
                    } label: {
                        Label("Queue controls", systemImage: "playpause")
                    }
                }
            }
        }
        .confirmationDialog(
            pendingConfirmation?.prompt ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingConfirmation
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                run { await performConfirmed(action) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Action failed",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task {
            if service == nil { service = store.service(for: instance) }
            await load()
        }
        .refreshable {
            await store.refresh()
            await load()
        }
    }

    // MARK: Sections

    @ViewBuilder private var headerSection: some View {
        Section {
            DetailHeader(
                instance: instance,
                health: configured ? (status?.health ?? .unknown) : .unknown,
                configured: configured,
                summary: status?.summaryLine,
                chips: status?.headline ?? []
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private var problemsSection: some View {
        if let problems = status?.problems, !problems.isEmpty {
            Section("Problems") {
                ForEach(problems) { ProblemRow(problem: $0) }
            }
        }
    }

    @ViewBuilder private var primaryActivitySection: some View {
        Section(instance.serviceType.primaryActivityNoun) {
            if isLoading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else if let loadError {
                Label(loadError.userMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if activity.isEmpty {
                Text("Nothing active").foregroundStyle(.secondary)
            } else {
                ForEach(activity) { item in
                    ActivityRow(item: item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            trailingActions(for: item)
                        }
                        .swipeActions(edge: .leading) {
                            leadingActions(for: item)
                        }
                }
            }
        }
    }

    @ViewBuilder private var listingSections: some View {
        if let service {
            if let listing = service as? UpcomingListing {
                LazyActivityDisclosure(title: "Upcoming", systemImage: "calendar") {
                    await activityResult { try await listing.fetchUpcoming(days: lookaheadDays) }
                }
            }
            if let listing = service as? MissingListing {
                LazyActivityDisclosure(
                    title: "Missing",
                    systemImage: "tray.and.arrow.down",
                    onSearch: service is ManualSearching
                        ? { item in run { await store.searchForItem(item, on: instance) } }
                        : nil
                ) {
                    await activityResult { try await listing.fetchMissing() }
                }
            }
            if let listing = service as? HistoryListing {
                LazyActivityDisclosure(
                    title: "History",
                    systemImage: "clock.arrow.circlepath",
                    onRetry: instance.serviceType.supportsDownloadControl
                        ? { item in run { await store.retryFailedItem(item, on: instance) } }
                        : nil
                ) {
                    await activityResult { try await listing.fetchRecentHistory() }
                }
            }
            if let listing = service as? RecentlyAddedListing {
                LazyActivityDisclosure(title: "Recently added", systemImage: "sparkles") {
                    await activityResult { try await listing.fetchRecentlyAdded() }
                }
            }
            if let listing = service as? ApplicationSyncListing {
                LazyActivityDisclosure(title: "Applications", systemImage: "arrow.left.arrow.right") {
                    await activityResult { try await listing.fetchApplications() }
                }
            }
        }
    }

    @ViewBuilder private var webUISection: some View {
        if let url = instance.baseURL {
            Section {
                Link(destination: url) {
                    Label("Open \(instance.serviceType.displayName) web UI", systemImage: "safari")
                }
            }
        }
    }

    // MARK: Swipe actions

    @ViewBuilder private func trailingActions(for item: ActivityItem) -> some View {
        let type = instance.serviceType
        if type.supportsQueueRemoval {
            Button(role: .destructive) {
                pendingConfirmation = .remove(item, blocklist: false)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            if type.supportsBlocklistRemoval {
                Button {
                    pendingConfirmation = .remove(item, blocklist: true)
                } label: {
                    Label("Blocklist", systemImage: "hand.raised")
                }
                .tint(.orange)
            }
        }
        if type.supportsDownloadControl, item.severity == .error {
            Button {
                run { await store.retryFailedItem(item, on: instance) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .tint(.blue)
        }
        if type.supportsSessionTermination {
            Button(role: .destructive) {
                pendingConfirmation = .stop(item)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        if type.supportsRequestApproval {
            Button {
                run { await store.declineRequest(item, on: instance) }
            } label: {
                Label("Decline", systemImage: "xmark")
            }
            .tint(.red)
        }
    }

    @ViewBuilder private func leadingActions(for item: ActivityItem) -> some View {
        let type = instance.serviceType
        if type.supportsRequestApproval {
            Button {
                run { await store.approveRequest(item, on: instance) }
            } label: {
                Label("Approve", systemImage: "checkmark")
            }
            .tint(.green)
        }
        if type.supportsDownloadControl {
            let paused = (item.status ?? "").lowercased().contains("pause")
            Button {
                run { await store.setItemPaused(!paused, item, on: instance) }
            } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
            }
            .tint(paused ? .green : .orange)
        }
    }

    // MARK: Action plumbing

    private func performConfirmed(_ action: PendingAction) async -> FleetError? {
        switch action {
        case let .remove(item, blocklist):
            return await store.removeQueueItem(item, on: instance, blocklist: blocklist)
        case let .stop(item):
            return await store.terminateSession(item, on: instance)
        }
    }

    /// Runs an action, surfaces any error, and reloads the activity list to reflect the new state.
    private func run(_ action: @escaping () async -> FleetError?) {
        Task {
            if let error = await action() {
                actionError = error.userMessage
            }
            await load()
        }
    }

    private func load() async {
        guard let service else {
            activity = []
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            activity = try await service.fetchActivity()
        } catch {
            loadError = error
        }
    }
}

/// Wraps a listing fetch into a `Result` for the lazy disclosure sections. Takes an untyped
/// throwing closure (typed-throws doesn't propagate cleanly through an existential here) and
/// narrows to `FleetError` in the catch.
private func activityResult(
    _ body: () async throws -> [ActivityItem]
) async -> Result<[ActivityItem], FleetError> {
    do {
        return .success(try await body())
    } catch let error as FleetError {
        return .failure(error)
    } catch {
        return .failure(.transport("Couldn't load"))
    }
}

/// A collapsible detail section (Upcoming / Missing / History / Recently added) that loads its list
/// on first expand, so the detail screen opens fast and only fetches what you look at (spec §6).
private struct LazyActivityDisclosure: View {
    let title: String
    let systemImage: String
    /// When set, failed (`.error`) rows get a "Retry" swipe action — used for SABnzbd History
    /// so a failed download can be re-tried in place (spec §6.4).
    var onRetry: ((ActivityItem) -> Void)? = nil
    /// When set, rows get a "Search" swipe action — used for the *arr Missing list to trigger a
    /// manual search for that wanted item (spec §6.1).
    var onSearch: ((ActivityItem) -> Void)? = nil
    let load: () async -> Result<[ActivityItem], FleetError>

    @State private var expanded = false
    @State private var phase: Phase = .idle

    private enum Phase {
        case idle, loading
        case loaded([ActivityItem])
        case failed(FleetError)
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                content
            } label: {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
            }
        }
        .onChange(of: expanded) { _, isOpen in
            if isOpen, case .idle = phase {
                Task { await performLoad() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        case .loaded(let items):
            if items.isEmpty {
                Text("Nothing here").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    ActivityRow(item: item)
                        .swipeActions(edge: .trailing) {
                            if let onRetry, item.severity == .error {
                                Button {
                                    onRetry(item)
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if let onSearch {
                                Button {
                                    onSearch(item)
                                } label: {
                                    Label("Search", systemImage: "magnifyingglass")
                                }
                                .tint(.indigo)
                            }
                        }
                }
            }
        case .failed(let error):
            Label(error.userMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func performLoad() async {
        phase = .loading
        switch await load() {
        case .success(let items): phase = .loaded(items)
        case .failure(let error): phase = .failed(error)
        }
    }
}

private enum PendingAction: Identifiable {
    case remove(ActivityItem, blocklist: Bool)
    case stop(ActivityItem)

    var id: String {
        switch self {
        case let .remove(item, blocklist): "remove-\(blocklist)-\(item.id)"
        case let .stop(item): "stop-\(item.id)"
        }
    }

    var prompt: String {
        switch self {
        case let .remove(item, blocklist):
            blocklist
                ? "Remove and blocklist “\(item.title)”? It will be blocked and searched again."
                : "Remove “\(item.title)” from the queue?"
        case let .stop(item):
            "Stop the stream “\(item.title)”?"
        }
    }

    var confirmLabel: String {
        switch self {
        case let .remove(_, blocklist): blocklist ? "Remove & Blocklist" : "Remove"
        case .stop: "Stop Stream"
        }
    }
}

/// The detail screen's health hero: a service badge tinted by state, the current verdict, a summary
/// line, and the headline metric chips — echoing the dashboard card so the two screens feel like one
/// app. Calm and neutral while healthy; tinted when the instance needs attention (spec §9.6).
private struct DetailHeader: View {
    let instance: FleetInstance
    let health: HealthState
    let configured: Bool
    let summary: String?
    let chips: [MetricChip]

    @Environment(\.colorScheme) private var colorScheme

    private var troubled: Bool { !configured || health.isProblem }
    private var tint: Color { configured ? health.tint : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(troubled ? tint.opacity(0.16) : Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: instance.serviceType.systemImageName)
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(troubled ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: configured ? health.systemImageName : "minus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(configured
                                ? (health == .healthy ? AnyShapeStyle(Color.green) : AnyShapeStyle(health.tint))
                                : AnyShapeStyle(Color.orange))
                        Text(configured ? health.displayLabel : "Not configured")
                            .font(.headline)
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if !chips.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) { ForEach(chips) { MetricChipView(chip: $0) } }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurface(cornerRadius: 20, tint: troubled ? tint : nil))
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if !configured { return "Add credentials in Settings to monitor this instance." }
        if let summary, !summary.isEmpty { return summary }
        return instance.serviceType.displayName
    }
}

private struct ProblemRow: View {
    let problem: Problem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title).font(.subheadline.weight(.medium))
                if let detail = problem.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch problem.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .cosmetic: "info.circle"
        }
    }

    private var color: Color {
        switch problem.severity {
        case .error: .red
        case .warning: .yellow
        case .cosmetic: .gray
        }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let artworkURL = item.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.06)
                    }
                }
                .frame(width: 44, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    if let status = item.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = item.progress {
                    ProgressView(value: min(max(progress, 0), 1))
                }
                if !item.fields.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(item.fields) { field in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(field.label).font(.caption2).foregroundStyle(.secondary)
                                Text(field.value).font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
