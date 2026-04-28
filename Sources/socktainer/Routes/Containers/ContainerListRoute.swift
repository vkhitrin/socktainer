import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Vapor

struct ContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol
    let imageClient: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/containers/json",
            use: ContainerListRoute.handler(client: client, imageClient: imageClient)
        )
    }
}

extension ContainerListRoute {
    private static func stoppedCompletions(
        for containers: [ContainerSnapshot],
        attachSessionManager: StoppedContainerAttachSessionManager?
    ) async -> [String: StoppedContainerCompletion] {
        guard let attachSessionManager else {
            return [:]
        }

        // NOTE: Apple container snapshots do not expose a non-blocking "last
        // exit status" field for general stopped containers. Keep `/containers/json`
        // cheap and use only socktainer's cached attach completions here instead
        // of probing stopped sandboxes with `wait`.
        return await attachSessionManager.completions(containerIDs: containers.map(\.id))
    }

    static func handler(client: ClientContainerProtocol, imageClient: ClientImageProtocol) -> @Sendable (Request) async throws -> [ContainerSummary] {
        { req in
            let query = try req.query.decode(ContainerListQuery.self)
            let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self]
            let showAll = query.all ?? false

            var parsedFilters = try DockerContainerFilterUtility.parseContainerFilters(
                filtersParam: query.filters,
                logger: req.logger
            )
            let requestedExitCodes = Set((parsedFilters.removeValue(forKey: "exited") ?? []).compactMap(Int64.init))
            var containers = try await client.list(showAll: showAll, filters: parsedFilters)
            containers.sort {
                let lhs = AppleContainerTimestampResolver.containerCreationDate($0) ?? .distantPast
                let rhs = AppleContainerTimestampResolver.containerCreationDate($1) ?? .distantPast
                return lhs > rhs
            }
            let completionByID = await stoppedCompletions(
                for: containers,
                attachSessionManager: req.application.storage[StoppedContainerAttachSessionManagerKey.self]
            )
            if !requestedExitCodes.isEmpty {
                containers = containers.filter { container in
                    guard let completion = completionByID[container.id] else {
                        return false
                    }
                    return requestedExitCodes.contains(completion.exitCode)
                }
            }
            if let limit = query.limit, limit >= 0 {
                containers = Array(containers.prefix(limit))
            }

            var summaries: [ContainerSummary] = []
            summaries.reserveCapacity(containers.count)

            for container in containers {
                let imageManifestDescriptor = await ContainerPresentationUtility.resolvedImageManifestDescriptor(
                    for: container,
                    imageClient: imageClient,
                    appSupportURL: appleContainerAppSupportUrl
                )
                let sizeValue: Int64?
                if query.size ?? false {
                    if let usage = try? await client.diskUsage(id: container.id) {
                        sizeValue = Int64(usage)
                    } else {
                        sizeValue = nil
                    }
                } else {
                    sizeValue = nil
                }

                summaries.append(
                    ContainerPresentationUtility.containerSummary(
                        from: container,
                        size: sizeValue,
                        completion: completionByID[container.id],
                        imageManifestDescriptor: imageManifestDescriptor
                    )
                )
            }

            return summaries
        }
    }
}
