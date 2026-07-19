import SwiftUI
import FleetarrKit

/// Per-instance detail screen (spec §6, §8): current health, the problems list, the primary
/// activity list (queue/sessions/requests), and a direct link to the service's own web UI.
struct InstanceDetailView: View {
    @Environment(FleetStore.self) private var store
    let instance: FleetInstance

    @State private var activity: [ActivityItem] = []
    @State private var isLoading = false
    @State private var loadError: FleetError?

    private var status: InstanceStatus? { store.status(for: instance) }
    private var configured: Bool { store.hasStoredSecret(for: instance) }

    var body: some View {
        List {
            Section("Status") {
                StatusIndicator(state: configured ? (status?.health ?? .unknown) : .unknown)
                if !configured {
                    Label("No credentials stored for this instance", systemImage: "key.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let summary = status?.summaryLine {
                    Text(summary).foregroundStyle(.secondary)
                }
                if let chips = status?.headline, !chips.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) { ForEach(chips) { MetricChipView(chip: $0) } }
                    }
                    .scrollIndicators(.hidden)
                }
            }

            if let problems = status?.problems, !problems.isEmpty {
                Section("Problems") {
                    ForEach(problems) { ProblemRow(problem: $0) }
                }
            }

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
                    ForEach(activity) { ActivityRow(item: $0) }
                }
            }

            if let url = instance.baseURL {
                Section {
                    Link(destination: url) {
                        Label("Open \(instance.serviceType.displayName) web UI", systemImage: "safari")
                    }
                }
            }
        }
        .navigationTitle(instance.label)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable {
            await store.refresh()
            await load()
        }
    }

    private func load() async {
        guard let service = store.service(for: instance) else {
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
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
