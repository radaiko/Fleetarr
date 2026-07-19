import Foundation

/// Builds the right ``FleetService`` for a given instance. Injectable so the app (and tests) can
/// supply mocks or a subset of implemented integrations.
public protocol FleetServiceFactory: Sendable {
    func makeService(for instance: FleetInstance, credential: String) throws(FleetError) -> any FleetService
}

/// Production factory that dispatches on ``ServiceType`` to the concrete client.
public struct DefaultFleetServiceFactory: FleetServiceFactory {
    public init() {}

    public func makeService(
        for instance: FleetInstance,
        credential: String
    ) throws(FleetError) -> any FleetService {
        let context = try ServiceContext(instance: instance, credential: credential)
        switch instance.serviceType {
        case .sonarr:
            return SonarrClient(context: context)
        case .radarr:
            return RadarrClient(context: context)
        case .prowlarr:
            return ProwlarrClient(context: context)
        case .seerr:
            return SeerrClient(context: context)
        case .sabnzbd:
            return SABnzbdClient(context: context)
        case .plex:
            return PlexClient(context: context)
        case .jellyfin:
            return JellyfinClient(context: context)
        }
    }
}
