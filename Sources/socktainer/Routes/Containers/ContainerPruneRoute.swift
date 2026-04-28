import Vapor

struct ContainerPruneRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/prune", use: handler)
    }
}

extension ContainerPruneRoute {
    func handler(req: Request) async throws -> ContainerPruneResponse {
        let query = try req.query.decode(ContainerPruneQuery.self)
        let logger = req.logger

        let parsedFilters = try DockerContainerFilterUtility.parseContainerPruneFilters(
            filtersParam: query.filters,
            logger: logger
        )

        do {
            let existingContainers = try await client.list(showAll: true, filters: [:])
            let result = try await client.prune(filters: parsedFilters)
            if let broadcaster = req.eventBroadcaster {
                let deletedContainerSet = Set(result.deletedContainers)
                for container in existingContainers where deletedContainerSet.contains(container.id) {
                    await ContainerEventUtility.broadcastContainerEvent(
                        request: req,
                        status: "destroy",
                        container: container,
                        containerID: container.id
                    )
                }
                let event = DockerEvent.simpleEvent(
                    id: "containers",
                    type: "container",
                    status: "prune",
                    from: "containers",
                    name: "containers"
                )
                await broadcaster.broadcast(event)
            } else {
                req.logger.warning("Event broadcaster not configured; skipping container prune event")
            }
            return ContainerPruneResponse(
                containersDeleted: result.deletedContainers.isEmpty ? nil : result.deletedContainers,
                spaceReclaimed: result.spaceReclaimed
            )
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            req.logger.error("Failed to prune containers: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune containers: \(error.localizedDescription)")
        }
    }
}
