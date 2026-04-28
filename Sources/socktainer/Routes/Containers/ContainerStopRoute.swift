import ContainerizationError
import Vapor

struct ContainerStopRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/stop", use: ContainerStopRoute.handler(client: client))
    }
}

extension ContainerStopRoute {
    private static func abortForStopError(_ error: any Error, id: String) -> Abort {
        ContainerMutationRouteUtility.abort(
            for: error,
            containerID: id,
            operation: "stop",
            treatAnyClientErrorAsNotFound: true
        )
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerStopQuery.self)
            let signal = try ContainerSignalUtility.validatedSignal(query.signal, action: "stop")
            let timeout = try ContainerSignalUtility.validatedTimeout(query.t, action: "stop")

            guard let container = try await client.getContainer(id: id) else {
                throw ContainerEventUtility.notFoundAbort(containerID: id)
            }

            if container.status != .running {
                return Response(status: .notModified)
            }

            do {
                try await client.stop(id: id, signal: signal, timeout: timeout)
            } catch {
                throw abortForStopError(error, id: id)
            }

            await ContainerEventUtility.broadcastContainerEvent(
                request: req,
                status: "stop",
                container: container,
                containerID: id
            )

            return Response(status: .noContent)
        }
    }
}
