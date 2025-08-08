import Vapor

struct ContainerListQuery: Content {
    var all: Bool?
}

struct ContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "containers", "json", use: ContainerListRoute.handler(client: client))
        // also handle without version prefix
        routes.get("containers", "json", use: ContainerListRoute.handler(client: client))
    }
}

extension ContainerListRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> [RESTContainerSummary] {
        { req in
            let query = try req.query.decode(ContainerListQuery.self)
            let showAll = query.all ?? false

            let containers = try await client.list(showAll: showAll)

            return containers.map {
                RESTContainerSummary(
                    Id: $0.id,
                    Names: ["/" + $0.id],
                    Image: $0.configuration.image.reference,
                    ImageID: $0.configuration.image.digest,
                    State: $0.status.rawValue
                )
            }
        }
    }
}
