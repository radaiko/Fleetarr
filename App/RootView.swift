import SwiftUI
import FleetarrKit

/// Top-level navigation per the information architecture (spec §8): a Fleet dashboard and a
/// Settings area, adapting to platform. This is the Phase-1 scaffold; the live dashboard and
/// instance management screens are built on top of `FleetarrKit`.
struct RootView: View {
    var body: some View {
        LockGate {
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
}

#Preview {
    RootView()
}
