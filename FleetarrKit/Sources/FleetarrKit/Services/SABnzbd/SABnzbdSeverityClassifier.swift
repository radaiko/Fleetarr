import Foundation

/// Classifies SABnzbd queue/history items into user-facing severities rather than passing raw
/// SABnzbd strings through unfiltered (spec §6.4).
///
/// - **Error** — failed download, failed unpack/repair/verify, disk-full, no server, auth failure.
/// - **Warning** — paused item/queue, or a non-fatal status message.
/// - **Cosmetic** — known-benign warnings (e.g. the confirmed-benign "non-writable special-character
///   filename"); shown in detail but **must not** count toward the problem badge (spec §6.4).
///
/// The cosmetic mapping is user-editable via an ignore-list of case-insensitive substrings, since
/// which warnings are "noise" is server-specific and only learned by observation (spec §6.4).
public enum SABnzbdSeverityClassifier {
    /// Seeded benign patterns. The confirmed-benign case from the existing stack is the
    /// non-writable special-character filename warning (spec §6.4); users add more.
    public static let defaultCosmeticPatterns: [String] = [
        "non-writable special-character filename",
    ]

    /// Substrings in a `fail_message` that indicate a genuine post-processing / provider error.
    static let errorKeywords: [String] = [
        "unpack failed", "unpacking failed", "repair failed", "verification failed",
        "cannot connect", "couldn't connect", "connection refused", "no server",
        "out of retention", "retention", "disk full", "no space", "not enough disk",
        "password", "authenti", "crc", "damaged", "moving failed", "download failed",
        "aborted", "no articles", "missing articles", "too many bad articles",
    ]

    /// Returns the severity for an item, or `nil` if the item isn't a problem (e.g. downloading
    /// or completed cleanly).
    ///
    /// - Parameters:
    ///   - status: the item's `status` field (e.g. "Downloading", "Failed", "Paused").
    ///   - failMessage: the item's `fail_message`, if any.
    ///   - ignorePatterns: user-provided cosmetic substrings, added to the defaults.
    public static func classify(
        status: String,
        failMessage: String? = nil,
        ignorePatterns: [String] = []
    ) -> Problem.Severity? {
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let message = (failMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let messageLower = message.lowercased()
        let combined = normalizedStatus + " " + messageLower

        func isCosmetic() -> Bool {
            let patterns = (defaultCosmeticPatterns + ignorePatterns)
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }
            return patterns.contains { combined.contains($0) }
        }

        // Errors: an explicit failed status, or a fail_message that names a real failure.
        if normalizedStatus == "failed" || errorKeywords.contains(where: messageLower.contains) {
            return isCosmetic() ? .cosmetic : .error
        }

        // Warnings: paused, or any other non-fatal message attached to the item.
        if normalizedStatus == "paused" {
            return .warning
        }
        if !message.isEmpty {
            return isCosmetic() ? .cosmetic : .warning
        }

        return nil
    }
}
