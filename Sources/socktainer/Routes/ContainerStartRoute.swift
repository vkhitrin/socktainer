import Vapor

struct ContainerStartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        // let group = routes.grouped("containers")
        // group.get(":id", "json", use: ContainerStartRoute.handler(client: client))
    }
}

extension ContainerStartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            try await client.start(id: id)

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!

            let event = DockerEvent.simpleEvent(id: id, type: "container", status: "start")

            await broadcaster.broadcast(event)

            return .ok
        }
    }
}
