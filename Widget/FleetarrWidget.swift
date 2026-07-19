import WidgetKit
import SwiftUI
import FleetarrKit

/// Glanceable Fleet-status widget (spec §9.7): Home Screen / Lock Screen on iOS and the widget
/// gallery on macOS. Reads the shared snapshot the app publishes on each refresh.
struct FleetEntry: TimelineEntry {
    let date: Date
    let snapshot: FleetSnapshot?
}

struct FleetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetEntry {
        FleetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
        completion(FleetEntry(date: Date(), snapshot: SharedSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
        let entry = FleetEntry(date: Date(), snapshot: SharedSnapshotStore.read())
        // The app reloads timelines whenever it refreshes; this cadence is just a fallback.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct FleetWidgetEntryView: View {
    var entry: FleetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        #endif
        case .systemMedium: medium
        default: small
        }
    }

    private var badge: Int { entry.snapshot?.problemBadgeCount ?? 0 }
    private var worst: HealthState { entry.snapshot?.worstHealth ?? .unknown }
    private var isClear: Bool { badge == 0 }

    private var headline: String {
        guard entry.snapshot != nil else { return "Open Fleetarr" }
        return isClear ? "All clear" : "\(badge) problem\(badge == 1 ? "" : "s")"
    }

    // MARK: Families

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isClear ? "checkmark.seal.fill" : worst.widgetIcon)
                    .foregroundStyle(isClear ? .green : worst.widgetColor)
                    .font(.title2)
                Spacer()
                if !isClear {
                    Text("\(badge)").font(.system(.largeTitle, design: .rounded).weight(.bold))
                }
            }
            Spacer()
            Text(headline).font(.headline)
            Text("Fleet").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            small
                .frame(maxWidth: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach((entry.snapshot?.instances ?? []).prefix(4)) { instance in
                    HStack(spacing: 6) {
                        Image(systemName: instance.health.widgetIcon)
                            .foregroundStyle(instance.health.widgetColor)
                            .font(.caption)
                        Text(instance.label).font(.caption).lineLimit(1)
                        Spacer()
                    }
                }
                if (entry.snapshot?.instances ?? []).isEmpty {
                    Text("No instances").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    #if os(iOS)
    private var rectangular: some View {
        HStack {
            Image(systemName: isClear ? "checkmark.seal.fill" : worst.widgetIcon)
            Text(headline)
        }
        .font(.headline)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if isClear {
                Image(systemName: "checkmark.seal.fill")
            } else {
                Text("\(badge)").font(.system(.title2, design: .rounded).weight(.bold))
            }
        }
    }
    #endif
}

@main
struct FleetarrWidgetBundle: WidgetBundle {
    var body: some Widget {
        FleetarrWidget()
    }
}

struct FleetarrWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FleetarrWidget", provider: FleetProvider()) { entry in
            FleetWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Fleet Status")
        .description("Combined problem count and per-service status across your media stack.")
        .supportedFamilies(Self.supportedFamilies)
    }

    private static var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

// The widget target can't see the app's StatusIndicator mapping, so it keeps a tiny local copy.
private extension HealthState {
    var widgetIcon: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .unreachable: "wifi.slash"
        }
    }

    var widgetColor: Color {
        switch self {
        case .unknown: .gray
        case .healthy: .green
        case .warning: .yellow
        case .error: .red
        case .unreachable: .orange
        }
    }
}
