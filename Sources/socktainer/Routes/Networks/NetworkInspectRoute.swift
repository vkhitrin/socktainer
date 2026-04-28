import Foundation
import Vapor

struct NetworkInspectRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/networks/{id}", use: NetworkInspectRoute.handler(client: client))
    }

    static func handler(client: ClientNetworkProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing network ID")
            }
            let query = try req.query.decode(NetworkInspectQuery.self)
            _ = query.verbose
            if let scope = query.scope, !scope.isEmpty {
                switch scope {
                case "local":
                    break
                case "swarm", "global":
                    // Apple container only exposes local-scope networks, so a
                    // non-local scope filter can never match an implemented network.
                    throw Abort(.notFound, reason: "No such network: \(id)")
                default:
                    throw Abort(.badRequest, reason: "Invalid network scope: \(scope)")
                }
            }
            let logger = req.logger
            guard let network = try await client.getNetwork(id: id, logger: logger) else {
                throw Abort(.notFound, reason: "No such network: \(id)")
            }
            let encoded = try JSONEncoder().encode(network)
            guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw Abort(.internalServerError, reason: "Failed to encode network response")
            }
            payload = NetworkPresentationUtility.normalizedIPAMOptions(payload)
            return try JSONResponseUtility.response(object: payload)
        }
    }
}
