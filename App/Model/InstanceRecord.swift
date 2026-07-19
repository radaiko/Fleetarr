import Foundation
import SwiftData
import FleetarrKit

/// SwiftData persistence for a configured instance's **non-secret** metadata, synced via CloudKit
/// (spec §3.5). The secret stays in the Keychain keyed by ``id`` — never here.
///
/// CloudKit modeling rules (spec §3.5): no `@Attribute(.unique)`; every property has a default;
/// `extraHeaders` (a dictionary, not a native CloudKit type) is stored as Codable `Data`; the
/// service-type enum is stored as its `rawValue`. `updatedAt` is the tiebreaker for the dedup
/// reconciliation pass that replaces the missing uniqueness constraint.
@Model
final class InstanceRecord {
    var id: UUID = UUID()
    var serviceTypeRaw: String = ServiceType.sonarr.rawValue
    var label: String = ""
    var baseURLString: String = ""
    var allowInsecureTLS: Bool = false
    /// Codable-encoded `[String: String]`; dictionaries aren't a native CloudKit attribute type.
    var extraHeadersData: Data?
    /// Codable-encoded `[String]` of SABnzbd cosmetic ignore substrings (spec §6.4). Optional so
    /// this remains an additive, CloudKit-safe schema change (spec §3.5).
    var cosmeticIgnorePatternsData: Data?
    var isEnabled: Bool = true
    var isHiddenFromDashboard: Bool = false
    var sortOrder: Int = 0
    /// Last local mutation; used to pick the winner during CloudKit dedup reconciliation.
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        serviceType: ServiceType = .sonarr,
        label: String = "",
        baseURLString: String = "",
        allowInsecureTLS: Bool = false,
        extraHeaders: [String: String] = [:],
        cosmeticIgnorePatterns: [String] = [],
        isEnabled: Bool = true,
        isHiddenFromDashboard: Bool = false,
        sortOrder: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.serviceTypeRaw = serviceType.rawValue
        self.label = label
        self.baseURLString = baseURLString
        self.allowInsecureTLS = allowInsecureTLS
        self.extraHeadersData = Self.encodeHeaders(extraHeaders)
        self.cosmeticIgnorePatternsData = Self.encodePatterns(cosmeticIgnorePatterns)
        self.isEnabled = isEnabled
        self.isHiddenFromDashboard = isHiddenFromDashboard
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }

    var serviceType: ServiceType {
        get { ServiceType(rawValue: serviceTypeRaw) ?? .sonarr }
        set { serviceTypeRaw = newValue.rawValue }
    }

    var extraHeaders: [String: String] {
        get {
            guard let data = extraHeadersData,
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return decoded
        }
        set { extraHeadersData = Self.encodeHeaders(newValue) }
    }

    private static func encodeHeaders(_ headers: [String: String]) -> Data? {
        headers.isEmpty ? nil : try? JSONEncoder().encode(headers)
    }

    var cosmeticIgnorePatterns: [String] {
        get {
            guard let data = cosmeticIgnorePatternsData,
                  let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return decoded
        }
        set { cosmeticIgnorePatternsData = Self.encodePatterns(newValue) }
    }

    private static func encodePatterns(_ patterns: [String]) -> Data? {
        patterns.isEmpty ? nil : try? JSONEncoder().encode(patterns)
    }

    // MARK: Mapping to/from the kit's pure value type

    var fleetInstance: FleetInstance {
        FleetInstance(
            id: id,
            serviceType: serviceType,
            label: label,
            baseURLString: baseURLString,
            allowInsecureTLS: allowInsecureTLS,
            extraHeaders: extraHeaders,
            cosmeticIgnorePatterns: cosmeticIgnorePatterns,
            isEnabled: isEnabled,
            isHiddenFromDashboard: isHiddenFromDashboard,
            sortOrder: sortOrder
        )
    }

    func apply(_ instance: FleetInstance) {
        serviceType = instance.serviceType
        label = instance.label
        baseURLString = instance.baseURLString
        allowInsecureTLS = instance.allowInsecureTLS
        extraHeaders = instance.extraHeaders
        cosmeticIgnorePatterns = instance.cosmeticIgnorePatterns
        isEnabled = instance.isEnabled
        isHiddenFromDashboard = instance.isHiddenFromDashboard
        sortOrder = instance.sortOrder
    }

    static func from(_ instance: FleetInstance) -> InstanceRecord {
        InstanceRecord(
            id: instance.id,
            serviceType: instance.serviceType,
            label: instance.label,
            baseURLString: instance.baseURLString,
            allowInsecureTLS: instance.allowInsecureTLS,
            extraHeaders: instance.extraHeaders,
            cosmeticIgnorePatterns: instance.cosmeticIgnorePatterns,
            isEnabled: instance.isEnabled,
            isHiddenFromDashboard: instance.isHiddenFromDashboard,
            sortOrder: instance.sortOrder
        )
    }
}
