import Foundation
import Vapor

struct BuildPruneRoute: RouteCollection {
    let builderClient: ClientBuilderProtocol

    init(builderClient: ClientBuilderProtocol) {
        self.builderClient = builderClient
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/build/prune", use: handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let query = try req.query.decode(BuildPruneQuery.self)
        if let keepStorage = query.keepStorage, keepStorage < 0 {
            throw Abort(.badRequest, reason: "keep-storage must be non-negative")
        }
        if let reservedSpace = query.reservedSpace, reservedSpace < 0 {
            throw Abort(.badRequest, reason: "reserved-space must be non-negative")
        }
        if let maxUsedSpace = query.maxUsedSpace, maxUsedSpace < 0 {
            throw Abort(.badRequest, reason: "max-used-space must be non-negative")
        }
        if let minFreeSpace = query.minFreeSpace, minFreeSpace < 0 {
            throw Abort(.badRequest, reason: "min-free-space must be non-negative")
        }
        let logger = req.logger
        let parsedFilters = try DockerBuildFilterUtility.parseBuildPruneFilters(
            filtersParam: query.filters,
            logger: logger
        )

        do {
            let result = try await builderClient.prune(
                BuilderPruneRequest(
                    all: query.all ?? false,
                    filters: parsedFilters,
                    keepStorage: query.keepStorage,
                    reservedSpace: query.reservedSpace,
                    maxUsedSpace: query.maxUsedSpace,
                    minFreeSpace: query.minFreeSpace
                ),
                logger: logger
            )

            let payload: [String: Any] = [
                "CachesDeleted": result.deletedCaches.isEmpty ? NSNull() : result.deletedCaches,
                "SpaceReclaimed": result.spaceReclaimed,
            ]
            return try JSONResponseUtility.response(object: payload)
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            logger.error("Failed to prune build cache via buildctl: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune build cache: \(error.localizedDescription)")
        }
    }
}
