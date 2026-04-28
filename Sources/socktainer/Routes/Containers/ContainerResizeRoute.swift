import Vapor

struct ContainerResizeRoute: RouteCollection {
    let client: ClientContainerService
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/resize", use: ContainerResizeRoute.resize(client: client))
    }

    // NOTE: Apple container does not expose a Docker-compatible container TTY resize
    // path for the init process through the API surface socktainer uses here, so this
    // route must not pretend to succeed.
    static func resize(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let _ = try? req.query.get(Int.self, at: "h") else {
                throw Abort(.badRequest, reason: "Missing height parameter")
            }

            guard let _ = try? req.query.get(Int.self, at: "w") else {
                throw Abort(.badRequest, reason: "Missing width parameter")
            }

            guard let _ = try await client.getContainer(id: containerId) else {
                throw Abort(.notFound, reason: "No such container: \(containerId)")
            }

            return AppleContainerNotSupported.respond("container resize")
        }
    }
}
