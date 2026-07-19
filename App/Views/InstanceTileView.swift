import SwiftUI
import FleetarrKit

/// A dashboard tile for one instance (spec §5): label + service, a status glyph, headline metric
/// chips, and a per-tile state for unconfigured / never-refreshed / unreachable.
struct InstanceTileView: View {
    let instance: FleetInstance
    let status: InstanceStatus?
    let hasSecret: Bool

    private var effectiveHealth: HealthState {
        hasSecret ? (status?.health ?? .unknown) : .unknown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(instance.label, systemImage: instance.serviceType.systemImageName)
                    .font(.headline)
                Spacer()
                StatusIndicator(state: effectiveHealth, showsLabel: false)
            }

            Text(instance.serviceType.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var content: some View {
        if !hasSecret {
            Label("Not configured — add credentials", systemImage: "key.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let status {
            if !status.headline.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(status.headline) { MetricChipView(chip: $0) }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let summary = status.summaryLine {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if status.badgeCount > 0 {
                Label(
                    "^[\(status.badgeCount) problem](inflect: true)",
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
            }
        } else {
            Label("Not yet refreshed", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        var parts = [instance.label, instance.serviceType.displayName, effectiveHealth.displayLabel]
        if !hasSecret {
            parts.append("not configured")
        } else if let status {
            if let summary = status.summaryLine { parts.append(summary) }
            if status.badgeCount > 0 { parts.append("\(status.badgeCount) problems") }
        }
        return parts.joined(separator: ", ")
    }
}
