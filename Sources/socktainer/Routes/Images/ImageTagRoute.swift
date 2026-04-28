import ContainerAPIClient
import Vapor

struct ImageTagRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/tag", use: ImageTagRoute.handler)
    }
}

extension ImageTagRoute {
    static func handler(_ req: Request) async throws -> Response {
        guard let sourceImageName = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing image name parameter")
        }

        let query = try req.query.decode(ImageTagQuery.self)

        guard let repo = query.repo, !repo.isEmpty else {
            throw Abort(.badRequest, reason: "repo parameter is required")
        }

        let targetReference: String
        do {
            targetReference = try {
                if let tag = query.tag, !tag.isEmpty {
                    return try ClientImage.normalizeReference("\(repo):\(tag)")
                }
                return try ClientImage.normalizeReference(repo)
            }()
        } catch {
            throw Abort(.badRequest, reason: "Invalid target image reference")
        }

        let sourceImage: ClientImage
        do {
            sourceImage = try await ClientImage.get(reference: sourceImageName)
        } catch {
            throw Abort(.notFound, reason: "No such image: \(sourceImageName)")
        }

        do {
            _ = try await sourceImage.tag(new: targetReference)
            if let broadcaster = req.eventBroadcaster {
                let imageLabels = try? await sourceImage.config(for: currentPlatform()).config?.labels
                let event = DockerEvent.simpleEvent(
                    id: sourceImage.digest,
                    type: "image",
                    status: "tag",
                    from: sourceImage.reference,
                    name: targetReference,
                    image: targetReference,
                    labels: imageLabels ?? [:]
                )
                await broadcaster.broadcast(event)
            } else {
                req.logger.warning("Event broadcaster not configured; skipping image tag event")
            }
            return Response(status: .created)
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            req.logger.error("Failed to tag image: \(error)")
            throw Abort(.internalServerError, reason: "Failed to tag image: \(error.localizedDescription)")
        }
    }
}
