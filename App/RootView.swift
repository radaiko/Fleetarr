import SwiftUI

/// Single-column navigation on every platform (spec §8): the Fleet dashboard is the home, a card
/// pushes its detail, and Settings is reached from the dashboard toolbar. No sidebar — the grid
/// already shows every service, so a per-instance nav list would just duplicate it. Wrapped in the
/// optional app-lock (spec §9.3).
struct RootView: View {
    var body: some View {
        LockGate {
            NavigationStack {
                FleetDashboardView()
            }
        }
    }
}

#Preview {
    RootView()
}
