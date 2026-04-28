import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Vapor

struct ImageHistoryRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/history", use: ImageHistoryRoute.handler(client: client))
    }
}

extension ImageHistoryRoute {
    private static func patchImageHistoryJSON(_ object: inout Any) {
        guard var items = object as? [[String: Any]] else {
            return
        }

        for index in items.indices {
            if let tags = items[index]["Tags"] as? [Any], tags.isEmpty {
                items[index]["Tags"] = NSNull()
            }
        }

        object = items
    }

    private static func historyResponseItems(
        for image: ClientImage,
        requestedName: String,
        details: ImageDetail,
        preferredPlatform: Platform?,
        allImages: [ClientImage]
    ) async throws -> [ImageHistoryResponseItem] {
        let imageIndex = try await image.index()
        let manifests = ImageRouteUtility.prioritizedManifests(
            imageIndex.manifests,
            preferredPlatform: preferredPlatform
        )
        let references = DockerImageReferenceResolver.references(
            for: image,
            allImages: allImages,
            includeDigests: false
        )

        for descriptor in manifests {
            if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                referenceType == "attestation-manifest"
            {
                continue
            }

            guard let platform = descriptor.platform else {
                continue
            }

            let config: ContainerizationOCI.Image
            let manifest: ContainerizationOCI.Manifest
            do {
                config = try await image.config(for: platform)
                manifest = try await image.manifest(for: platform)
            } catch {
                continue
            }

            let history = config.history ?? []
            var remainingLayers = Array(manifest.layers)
            var items: [ImageHistoryResponseItem] = []

            for entry in history {
                let isEmptyLayer = entry.emptyLayer ?? false
                let itemSize: Int64

                if isEmptyLayer {
                    itemSize = 0
                } else if let layer = remainingLayers.first {
                    itemSize = layer.size
                    remainingLayers.removeFirst()
                } else {
                    itemSize = 0
                }

                items.insert(
                    ImageHistoryResponseItem(
                        id: "<missing>",
                        created: AppleContainerTimestampResolver.unixTimestampSeconds(entry.created ?? config.created),
                        createdBy: entry.createdBy ?? "",
                        tags: [],
                        size: itemSize,
                        comment: entry.comment ?? ""
                    ),
                    at: 0
                )
            }

            if !items.isEmpty {
                items[0] = ImageHistoryResponseItem(
                    id: image.digest,
                    created: items[0].created,
                    createdBy: items[0].createdBy,
                    tags: references.repoTags,
                    size: items[0].size,
                    comment: items[0].comment
                )
                return items
            }

            return [
                ImageHistoryResponseItem(
                    id: image.digest,
                    created: AppleContainerTimestampResolver.unixTimestampSeconds(config.created),
                    createdBy: "",
                    tags: references.repoTags,
                    size: manifest.layers.reduce(0) { $0 + $1.size },
                    comment: ""
                )
            ]
        }

        throw Abort(.notFound, reason: "No such image: \(requestedName)")
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let refOrId = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }

            let query = try req.query.decode(ImageHistoryQuery.self)
            let preferredPlatform = try ImageRouteUtility.platformOrNil(query.platform)
            let image = try await ImageRouteUtility.getImage(referenceOrID: refOrId)

            let details = try await image.details()
            let allImages = try await client.list(includeSystemImages: true)
            let items = try await historyResponseItems(
                for: image,
                requestedName: refOrId,
                details: details,
                preferredPlatform: preferredPlatform,
                allImages: allImages
            )
            let encoded = try JSONEncoder().encode(items)
            var object = try JSONSerialization.jsonObject(with: encoded)
            patchImageHistoryJSON(&object)
            return try ImageRouteUtility.jsonResponse(object)
        }
    }
}
