import SwiftUI

/// Wraps the app's content with the optional app-lock (spec §9.3): when enabled, it covers the UI
/// with a lock screen whenever the app is locked, and locks again when the app is backgrounded.
struct LockGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @State private var lock = AppLockController()

    @ViewBuilder let content: () -> Content

    private var isCovered: Bool { appLockEnabled && lock.isLocked }

    var body: some View {
        content()
            .overlay {
                if isCovered {
                    LockScreen(canAuthenticate: lock.canAuthenticate) {
                        await lock.authenticate()
                    }
                    .transition(.opacity)
                }
            }
            // Redact content while locked so nothing sensitive is visible behind the overlay.
            .privacySensitive(isCovered)
            .task(id: scenePhase) {
                switch scenePhase {
                case .active:
                    if isCovered { await lock.authenticate() }
                case .background:
                    lock.lockIfEnabled()
                default:
                    break
                }
            }
            .onChange(of: appLockEnabled) { _, enabled in
                if !enabled { lock.unlock() }
            }
    }
}

private struct LockScreen: View {
    let canAuthenticate: Bool
    let unlock: () async -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Fleetarr is locked")
                    .font(.headline)
                Button {
                    Task { await unlock() }
                } label: {
                    Label(canAuthenticate ? "Unlock" : "Continue", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .task { await unlock() }
        .accessibilityAddTraits(.isModal)
    }
}
