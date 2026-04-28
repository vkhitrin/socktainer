import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Vapor

struct ContainerKillRoute: RouteCollection {
    let client: ClientContainerService
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/kill", use: ContainerKillRoute.handler(client: client))
    }
}

extension ContainerKillRoute {
    private static func abortForKillError(_ error: any Error, containerId: String) -> Abort {
        ContainerMutationRouteUtility.abort(
            for: error,
            containerID: containerId,
            operation: "kill",
            notRunningReason: "Container \(containerId) is not running"
        )
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            let query = try req.query.decode(ContainerKillQuery.self)

            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Container ID is required")
            }

            let signal = try ContainerSignalUtility.validatedSignal(query.signal, action: "kill")
            let container = try await client.getContainer(id: containerId)

            do {
                try await client.kill(id: containerId, signal: signal)
                await ContainerEventUtility.broadcastContainerEvent(
                    request: req,
                    status: "kill",
                    container: container,
                    containerID: containerId
                )
                return Response(status: .noContent)
            } catch {
                req.logger.error("Failed to kill container \(containerId): \(error)")
                throw abortForKillError(error, containerId: containerId)
            }
        }
    }
}
