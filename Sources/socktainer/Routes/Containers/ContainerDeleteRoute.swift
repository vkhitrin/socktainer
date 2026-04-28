import Vapor

struct ContainerDeleteRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/containers/{id}", use: ContainerDeleteRoute.handler(client: client))
    }

}

extension ContainerDeleteRoute {
    private static func abortForDeleteError(_ error: any Error, id: String) -> Abort {
        ContainerMutationRouteUtility.abort(
            for: error,
            containerID: id,
            operation: "delete",
            notRunningReason: "Container \(id) is not running"
        )
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerDeleteQuery.self)
            if query.v == true {
                req.logger.debug("Ignoring container delete volume-removal flag for \(id)")
            }
            if query.link == true {
                req.logger.debug("Ignoring container delete link-removal flag for \(id)")
            }
            let force = query.force ?? false

            guard let container = try await client.getContainer(id: id) else {
                throw ContainerEventUtility.notFoundAbort(containerID: id)
            }

            if container.status == .running {
                guard force else {
                    throw Abort(.conflict, reason: "You cannot remove a running container: \(id). Stop the container before attempting removal or force remove")
                }
                do {
                    try await client.kill(id: id, signal: nil)
                    await ContainerEventUtility.broadcastContainerEvent(
                        request: req,
                        status: "kill",
                        container: container,
                        containerID: id
                    )
                } catch {
                    guard case .notRunning = (error as? ClientContainerError) else {
                        throw abortForDeleteError(error, id: id)
                    }
                }
            }

            do {
                try await client.delete(id: id)
            } catch {
                throw abortForDeleteError(error, id: id)
            }

            await ContainerEventUtility.broadcastContainerEvent(
                request: req,
                status: "destroy",
                container: container,
                containerID: id
            )

            return Response(status: .noContent)

        }
    }
}
