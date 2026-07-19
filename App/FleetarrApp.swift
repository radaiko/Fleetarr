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
        _store = State(initialValue: FleetStore(context: container.mainContext))
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
    }
}
