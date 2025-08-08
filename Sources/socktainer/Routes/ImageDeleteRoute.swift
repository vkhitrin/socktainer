import Vapor

struct ImageDeleteRoute: RouteCollection {
    let client: ClientImageProtocol
    func boot(routes: RoutesBuilder) throws {

        // DELETE /:version/images/<catchall>
        routes.delete(":version", "images", "**", use: ImageDeleteRoute.handler(client: client))

        // DELETE /images/<catchall>
        routes.delete("images", "**", use: ImageDeleteRoute.handler(client: client))

    }

}

extension ImageDeleteRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            // Catchall segments after /images/
            let parts = req.parameters.getCatchall()

            guard !parts.isEmpty else {
                throw Abort(.badRequest, reason: "Missing image reference")
            }

            let imageRef = parts.joined(separator: "/")
            print("ask to delete image with reference: \(imageRef)")
            try await client.delete(id: imageRef)

            // Optional: broadcast event
            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let event = DockerEvent.simpleEvent(id: imageRef, type: "image", status: "remove")
            await broadcaster.broadcast(event)

            return .ok

        }
    }
}
