import ContainerAPIClient
import ContainerizationOCI
import Vapor

struct ImageDeleteRoute: RouteCollection {
    let client: ClientImageProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/images/{name:.*}", use: ImageDeleteRoute.handler(client: client))
    }

}

extension ImageDeleteRoute {
    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            // Get image name from regex pattern parameter
            guard let imageRef = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            let query = try req.query.decode(ImageDeleteQuery.self)
            if let platforms = query.platforms, !platforms.isEmpty {
                let requestedPlatforms = try platforms.map(platformOrThrow)
                let current = currentPlatform()
                guard requestedPlatforms.allSatisfy({ $0 == current }) else {
                    throw Abort(.badRequest, reason: "platform-specific image delete is not supported outside the current Apple container platform")
                }
            }

            let resolvedImage: ClientImage?
            do {
                resolvedImage = try await ClientImage.get(reference: imageRef)
            } catch {
                resolvedImage = nil
            }

            do {
                try await client.delete(id: imageRef, force: query.force ?? false)
            } catch let error as ClientImageError {
                switch error {
                case .notFound(let id):
                    throw Abort(.notFound, reason: "No such image: \(id)")
                case .inUse(let id):
                    throw Abort(.conflict, reason: "conflict: unable to delete \(id) (image is being used by a container)")
                }
            }

            // Optional: broadcast event
            try await ImageDeletionUtility.broadcastDeleteEvent(
                request: req,
                resolvedImage: resolvedImage,
                imageRef: imageRef,
                missingBroadcasterWarning: "Event broadcaster not configured; skipping image delete event"
            )

            let deleteResponse = [
                ImageDeletionUtility.deleteResponseItem(for: imageRef)
            ]

            return try await deleteResponse.encodeResponse(status: .ok, for: req)

        }
    }
}
