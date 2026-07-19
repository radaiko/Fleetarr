import SwiftUI
import FleetarrKit

/// Top-level navigation (spec §3.1, §8): a tab layout on compact iPhone, a `NavigationSplitView`
/// sidebar on iPad and Mac. Wrapped in the optional app-lock (spec §9.3).
struct RootView: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        LockGate {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                CompactRootView()
            } else {
                SidebarRootView()
            }
            #else
            SidebarRootView()
            #endif
        }
    }
}

/// iPhone layout: a Fleet tab and a Settings tab (spec §8).
private struct CompactRootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                FleetDashboardView()
            }
            .tabItem { Label("Fleet", systemImage: "square.grid.2x2") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// iPad / Mac layout: a persistent sidebar listing the Fleet dashboard, every instance grouped by
/// service type, and Settings, with the selection driving the detail column (spec §8).
private struct SidebarRootView: View {
    @Environment(FleetStore.self) private var store
    @State private var selection: SidebarSelection? = .fleet

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Fleet", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.fleet)

                ForEach(groupedServiceTypes, id: \.self) { type in
                    Section(type.displayName) {
                        ForEach(instances(of: type)) { instance in
                            Label(instance.label, systemImage: type.systemImageName)
                                .tag(SidebarSelection.instance(instance.id))
                        }
                    }
                }

                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarSelection.settings)
            }
            .navigationTitle("Fleetarr")
        } detail: {
            detailView
        }
    }

    @ViewBuilder private var detailView: some View {
        switch selection {
        case .settings:
            NavigationStack { SettingsView() }
        case let .instance(id):
            if let instance = store.instances.first(where: { $0.id == id }) {
                NavigationStack { InstanceDetailView(instance: instance) }
            } else {
                ContentUnavailableView("Select an instance", systemImage: "square.grid.2x2")
            }
        case .fleet, .none:
            NavigationStack { FleetDashboardView() }
        }
    }

    /// Service types that have at least one configured instance, in display order.
    private var groupedServiceTypes: [ServiceType] {
        ServiceType.allCases.filter { type in store.instances.contains { $0.serviceType == type } }
    }

    private func instances(of type: ServiceType) -> [FleetInstance] {
        store.instances.filter { $0.serviceType == type }
    }
}

private enum SidebarSelection: Hashable {
    case fleet
    case settings
    case instance(UUID)
}
