import Foundation
import Vapor

struct NetworkListRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/networks", use: NetworkListRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        let networkClient = ClientNetworkService()
        let query = try req.query.decode(NetworkListQuery.self)
        let parsedFilters = try DockerNetworkFilterUtility.parseNetworkFilters(filtersParam: query.filters, defaultDangling: false, logger: req.logger)

        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)

        do {
            let networks = try await networkClient.list(filters: filtersJSONString, logger: req.logger)
            let encoded = try JSONEncoder().encode(networks)
            guard let objects = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else {
                throw Abort(.internalServerError, reason: "Failed to encode networks response")
            }
            return try JSONResponseUtility.response(
                object: NetworkPresentationUtility.normalizedIPAMOptions(objects)
            )
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            throw Abort(.internalServerError, reason: "Failed to list networks: \(error)")
        }
    }
}
