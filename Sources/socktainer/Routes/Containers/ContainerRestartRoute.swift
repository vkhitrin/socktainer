import ContainerizationError
import Vapor

struct ContainerRestartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/restart", use: ContainerRestartRoute.handler(client: client))
    }
}

extension ContainerRestartRoute {
    private static func abortForRestartError(_ error: any Error, id: String) -> Abort {
        ContainerMutationRouteUtility.abort(
            for: error,
            containerID: id,
            operation: "restart"
        )
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerRestartQuery.self)
            let signal = try ContainerSignalUtility.validatedSignal(query.signal, action: "restart")
            let timeout = try ContainerSignalUtility.validatedTimeout(query.t, action: "restart")
            let container = try await client.getContainer(id: id)

            do {
                try await client.restart(id: id, signal: signal, timeout: timeout)
            } catch {
                req.logger.error("Failed to restart container \(id): \(error)")
                throw abortForRestartError(error, id: id)
            }

            await ContainerEventUtility.broadcastContainerEvent(
                request: req,
                status: "restart",
                container: container,
                containerID: id
            )

            return .noContent
        }
    }
}
