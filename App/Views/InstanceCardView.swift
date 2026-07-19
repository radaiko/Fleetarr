import SwiftUI
import FleetarrKit

/// A dashboard card for one instance (spec §5). Phone-native: a tactile rounded card led by a
/// service badge, with the instance's headline metrics as the hero content. It stays calm and
/// neutral while healthy; a troubled instance announces itself through a status-tinted badge, a
/// soft card wash, and its glyph — never through hue alone (color is always paired with an icon and
/// text, spec §9.6). Shared across platforms: one column on phone, a grid tile on Mac/iPad.
struct InstanceCardView: View {
    let instance: FleetInstance
    let status: InstanceStatus?
    let configured: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var health: HealthState {
        configured ? (status?.health ?? .unknown) : .unknown
    }

    /// Whether the instance needs a second look — drives the tinted (vs. calm neutral) treatment.
    private var troubled: Bool {
        !configured || health == .warning || health == .error || health == .unreachable
    }

    /// The one color that expresses this card's state (only used when `troubled`).
    private var accent: Color {
        configured ? health.tint : .orange
    }

    private var metricChips: [MetricChip] {
        guard configured, health != .unreachable else { return [] }
        return Array((status?.headline ?? []).prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metricChips.isEmpty ? 0 : 14) {
            headerRow
            if !metricChips.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    ForEach(metricChips) { statPair($0) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(troubled ? accent.opacity(0.28) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.0 : 0.06), radius: 7, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        #if os(macOS)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.label)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(troubled ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            statusGlyph
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var iconBadge: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(troubled ? accent.opacity(0.16) : Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055))
            .frame(width: 46, height: 46)
            .overlay(
                Image(systemName: instance.serviceType.systemImageName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(troubled ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            )
    }

    @ViewBuilder private var statusGlyph: some View {
        if !configured {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: health.systemImageName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(health == .healthy ? AnyShapeStyle(Color.green) : AnyShapeStyle(health.tint))
        }
    }

    // MARK: Metrics — the numbers are the hero

    private func statPair(_ chip: MetricChip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chip.value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor(chip))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(chip.label)
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: Styling

    private var subtitle: String {
        if !configured { return "Not configured" }
        if let line = status?.summaryLine, !line.isEmpty { return line }
        return health == .unknown ? "Not checked yet" : health.displayLabel
    }

    private func valueColor(_ chip: MetricChip) -> Color {
        switch chip.emphasis {
        case .normal: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var cardSurface: some View {
        ZStack {
            baseSurface
            if troubled { accent.opacity(0.09) }
            #if os(macOS)
            if hovering { Color.primary.opacity(0.04) }
            #endif
        }
    }

    private var baseSurface: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private var accessibilityText: String {
        var parts = [instance.label, instance.serviceType.displayName]
        if !configured {
            parts.append("not configured")
        } else {
            parts.append(health.displayLabel)
            parts.append(contentsOf: metricChips.map { "\($0.value) \($0.label)" })
        }
        return parts.joined(separator: ", ")
    }
}
