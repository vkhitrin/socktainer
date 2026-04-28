import ContainerizationOCI
import Vapor

struct ImagePruneRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/prune", use: handler)
    }
}

extension ImagePruneRoute {
    func handler(req: Request) async throws -> Response {
        let query = try req.query.decode(ImagePruneQuery.self)
        let logger = req.logger

        let parsedFilters = try DockerImageFilterUtility.parseImagePruneFilters(
            filterParam: query.filters,
            logger: logger
        )

        do {
            let existingImages = try await client.list()
            let result = try await client.prune(filters: parsedFilters, logger: logger)
            if let broadcaster = req.eventBroadcaster {
                let existingImageMap = Dictionary(uniqueKeysWithValues: existingImages.map { ($0.reference, $0) })
                for imageRef in result.deletedImages {
                    let resolvedImage = existingImageMap[imageRef]
                    try await ImageDeletionUtility.broadcastDeleteEvent(
                        request: req,
                        resolvedImage: resolvedImage,
                        imageRef: imageRef,
                        missingBroadcasterWarning: "Event broadcaster not configured; skipping image prune event"
                    )
                }
                let event = DockerEvent.simpleEvent(
                    id: "images",
                    type: "image",
                    status: "prune",
                    from: "images",
                    name: "images",
                    image: "images"
                )
                await broadcaster.broadcast(event)
            } else {
                req.logger.warning("Event broadcaster not configured; skipping image prune event")
            }

            let imagesDeleted = result.deletedImages.map(ImageDeletionUtility.deleteResponseItem(for:))

            let encodedImagesDeleted: Any
            if imagesDeleted.isEmpty {
                encodedImagesDeleted = NSNull()
            } else {
                let encodedItems = imagesDeleted.map { item -> [String: Any] in
                    var object: [String: Any] = [:]
                    object["Untagged"] = item.untagged ?? NSNull()
                    object["Deleted"] = item.deleted ?? NSNull()
                    return object
                }
                encodedImagesDeleted = encodedItems
            }

            let payload: [String: Any] = [
                "ImagesDeleted": encodedImagesDeleted,
                "SpaceReclaimed": result.spaceReclaimed,
            ]
            return try JSONResponseUtility.response(object: payload)
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            req.logger.error("Failed to prune images: \(error)")
            throw Abort(.internalServerError, reason: "Failed to prune images: \(error.localizedDescription)")
        }
    }
}
