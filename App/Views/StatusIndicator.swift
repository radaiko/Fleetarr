import SwiftUI
import FleetarrKit

// Presentation mapping for health/metrics. Kept in the app layer so `FleetarrKit` stays UI-free.
// Every status pairs color with a distinct icon shape AND text so it never relies on hue alone
// (spec §9.6).

extension HealthState {
    var displayLabel: String {
        switch self {
        case .unknown: "Unknown"
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .error: "Error"
        case .unreachable: "Unreachable"
        }
    }

    var systemImageName: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .unreachable: "wifi.slash"
        }
    }

    var tint: Color {
        switch self {
        case .unknown: .gray
        case .healthy: .green
        case .warning: .yellow
        case .error: .red
        case .unreachable: .orange
        }
    }
}

/// A status glyph combining color + icon + (optional) text label (spec §9.6).
struct StatusIndicator: View {
    let state: HealthState
    var showsLabel: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.systemImageName)
                .foregroundStyle(state.tint)
            if showsLabel {
                Text(state.displayLabel)
                    .font(.subheadline.weight(.medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(state.displayLabel)")
    }
}

/// Renders a `MetricChip` as a small pill; emphasis is shown with color *and* icon, never color
/// alone (spec §9.6).
struct MetricChipView: View {
    let chip: MetricChip

    var body: some View {
        HStack(spacing: 4) {
            if let image = chip.systemImageName {
                Image(systemName: image).font(.caption2)
            }
            Text(chip.value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(chip.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(background, in: Capsule())
        .foregroundStyle(foreground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chip.label): \(chip.value)")
    }

    private var foreground: Color {
        switch chip.emphasis {
        case .normal: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    private var background: Color {
        switch chip.emphasis {
        case .normal: .gray.opacity(0.15)
        case .warning: .orange.opacity(0.15)
        case .error: .red.opacity(0.15)
        }
    }
}
