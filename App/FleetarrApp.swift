import SwiftUI
import SwiftData

@main
struct FleetarrApp: App {
    @State private var container: ModelContainer
    @State private var store: FleetStore

    init() {
        // syncEnabled must be read before the store opens (spec §3.5). Default on.
        let syncEnabled = UserDefaults.standard.object(forKey: "syncEnabled") as? Bool ?? true
        let container = Persistence.makeContainer(syncEnabled: syncEnabled)
        _container = State(initialValue: container)
        let store = FleetStore(context: container.mainContext)
        #if DEBUG
        // `--demo` seeds representative multi-state data for design work / screenshots (no network,
        // no store writes). Never present in release builds.
        if CommandLine.arguments.contains("--demo") { store.loadDemoData() }
        #endif
        _store = State(initialValue: store)

        Analytics.start()
        Analytics.appLaunched()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 960, height: 680)
        #endif

        #if os(macOS)
        // Glanceable menu-bar extra (spec §9.7): the fleet's combined problem count at a glance.
        MenuBarExtra {
            MenuBarContent()
                .environment(store)
                .modelContainer(container)
        } label: {
            Image(systemName: store.summary.problemBadgeCount == 0
                  ? "shippingbox"
                  : "exclamationmark.triangle.fill")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
