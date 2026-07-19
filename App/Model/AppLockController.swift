import Foundation
import Observation
import LocalAuthentication

/// Optional Face ID / Touch ID / passcode app-lock (spec §9.3). This is a **local, per-device**
/// setting — it does not sync via iCloud (spec §10.7) — because a stolen unlocked device with
/// Fleetarr installed can approve requests, delete queue items, and kill streams.
///
/// The enabled flag lives in `@AppStorage("appLockEnabled")` (local UserDefaults); this controller
/// only owns the transient locked/unlocked state.
@MainActor
@Observable
final class AppLockController {
    private(set) var isLocked: Bool

    init() {
        // Start locked if the feature is on, so a cold launch requires authentication.
        isLocked = UserDefaults.standard.bool(forKey: "appLockEnabled")
    }

    /// Whether the device can perform owner authentication (biometrics or passcode).
    var canAuthenticate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Re-lock when leaving the foreground, if the feature is enabled.
    func lockIfEnabled() {
        if UserDefaults.standard.bool(forKey: "appLockEnabled") {
            isLocked = true
        }
    }

    /// Clear the lock without authenticating — used when the user turns the feature off.
    func unlock() {
        isLocked = false
    }

    /// Prompt for Face ID / Touch ID / passcode and unlock on success.
    func authenticate() async {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics or passcode configured — don't lock the user out of their own app.
            isLocked = false
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Fleetarr"
            )
            isLocked = !success
        } catch {
            // Cancelled or failed — stay locked.
            isLocked = true
        }
    }
}
