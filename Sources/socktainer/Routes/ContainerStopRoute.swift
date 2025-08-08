import Vapor

struct ContainerStopRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.post(":version", "containers", ":id", "stop", use: ContainerStopRoute.handler(client: client))
        // also handle without version prefix
        routes.post("containers", ":id", "stop", use: ContainerStopRoute.handler(client: client))

    }
}

extension ContainerStopRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            try await client.stop(id: id)

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!

            let event = DockerEvent.simpleEvent(id: id, type: "container", status: "stop")

            await broadcaster.broadcast(event)

            return .ok
        }
    }
}
