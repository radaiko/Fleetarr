import SwiftUI
import FleetarrKit

/// A compact dashboard card for one instance (spec §5). Design intent: the grid stays calm and
/// grayscale while everything is healthy; a troubled instance announces itself through its status
/// rail and colored metrics. The numbers are the hero — large, rounded, monospaced.
struct InstanceCardView: View {
    let instance: FleetInstance
    let status: InstanceStatus?
    let configured: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var health: HealthState {
        configured ? (status?.health ?? .unknown) : .unknown
    }

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(railColor)
                .frame(width: 3)
                .padding(.vertical, 11)

            VStack(alignment: .leading, spacing: 12) {
                header
                Spacer(minLength: 0)
                metrics
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
        }
        .frame(minHeight: 96, alignment: .top)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        #if os(macOS)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: instance.serviceType.systemImageName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(instance.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            statusGlyph
        }
    }

    @ViewBuilder private var statusGlyph: some View {
        if !configured {
            Image(systemName: "minus.circle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            Image(systemName: health.systemImageName)
                .font(.footnote)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(health == .healthy ? AnyShapeStyle(.secondary) : AnyShapeStyle(health.tint))
        }
    }

    // MARK: Metrics

    @ViewBuilder private var metrics: some View {
        if !configured {
            caption("Not configured", color: .orange)
        } else if health == .unreachable {
            caption(status?.summaryLine ?? "Unreachable", color: .orange)
        } else if let chips = status?.headline, !chips.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                ForEach(chips.prefix(3)) { chip in
                    statPair(chip)
                }
                Spacer(minLength: 0)
            }
        } else {
            caption(status?.summaryLine ?? "—", color: .secondary)
        }
    }

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

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Styling

    private var railColor: Color {
        switch health {
        case .healthy: return .green.opacity(0.55)
        case .warning: return .yellow
        case .error: return .red
        case .unreachable: return .orange
        case .unknown: return .gray.opacity(0.35)
        }
    }

    private func valueColor(_ chip: MetricChip) -> Color {
        switch chip.emphasis {
        case .normal: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var cardFill: Color {
        let base = colorScheme == .dark ? 0.055 : 0.028
        return Color.primary.opacity(hovering ? base + 0.04 : base)
    }

    private var accessibilityText: String {
        var parts = [instance.label, instance.serviceType.displayName]
        if !configured {
            parts.append("not configured")
        } else {
            parts.append(health.displayLabel)
            if let chips = status?.headline {
                parts.append(contentsOf: chips.prefix(3).map { "\($0.value) \($0.label)" })
            }
        }
        return parts.joined(separator: ", ")
    }
}
