import Vapor

struct NetworkPruneRoute: RouteCollection {
    let client: ClientNetworkProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/prune", use: NetworkPruneRoute.handler)
    }

    static func handler(_ req: Request) async throws -> NetworkPruneResponse {
        let networkClient = ClientNetworkService()
        let query = try req.query.decode(NetworkListQuery.self)
        // Use utility to parse filters (default to dangling)
        let parsedFilters = try DockerNetworkFilterUtility.parseNetworkFilters(filtersParam: query.filters, defaultDangling: true, logger: req.logger)

        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)

        var deletedNetworks: [String] = []
        do {
            let networks = try await networkClient.list(filters: filtersJSONString, logger: req.logger)
            for network in networks {
                if network.name == "default" {
                    req.logger.info("Skipping deletion of default network: \(network.id ?? "")")
                    continue
                }
                do {
                    try await networkClient.delete(id: network.id ?? "", logger: req.logger)
                    if let networkId = network.id {
                        deletedNetworks.append(networkId)
                    }
                    if let broadcaster = req.eventBroadcaster {
                        let event = DockerEvent.simpleEvent(
                            id: network.id ?? "",
                            type: "network",
                            status: "remove",
                            from: network.name ?? "",
                            name: network.name ?? "",
                            labels: network.labels ?? [:]
                        )
                        await broadcaster.broadcast(event)
                    }
                } catch {
                    req.logger.error("Failed to delete network \(network.id ?? ""): \(error)")
                }
            }
            if let broadcaster = req.eventBroadcaster {
                let event = DockerEvent.simpleEvent(
                    id: "networks",
                    type: "network",
                    status: "prune",
                    from: "networks",
                    name: "networks"
                )
                await broadcaster.broadcast(event)
            } else {
                req.logger.warning("Event broadcaster not configured; skipping network prune event")
            }
            return NetworkPruneResponse(
                networksDeleted: deletedNetworks.isEmpty ? nil : deletedNetworks
            )
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            throw Abort(.internalServerError, reason: "Failed to prune networks: \(error)")
        }
    }
}
