import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Vapor

struct ImageListRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/json", use: ImageListRoute.handler(client: client))
    }
}

struct CustomImageDetail: Decodable {
    public let name: String
}

extension ImageListRoute {
    private static func imageCreatedAt(_ details: ImageDetail) -> Int64 {
        AppleContainerTimestampResolver.unixTimestampSeconds(details.variants.first?.config.created)
    }

    private static func matchesImageFilters(
        image: ClientImage,
        details: ImageDetail,
        filters: [String: [String]],
        imagesInUse: Set<String>,
        imageMetadata: [String: (created: Int64, name: String)]
    ) -> Bool {
        let createdAt = imageCreatedAt(details)
        let labels = details.variants.first?.config.config?.labels ?? [:]
        let reference = image.reference
        let displayName = details.name
        let isDangling = displayName.isEmpty || reference.contains("@sha256:")

        for (key, values) in filters {
            switch key {
            case "dangling":
                let matchesDangling = values.contains { value in
                    let wantDangling = value == "true" || value == "1"
                    return isDangling == wantDangling
                }
                if !matchesDangling {
                    return false
                }
            case "label":
                let matches = values.allSatisfy { filter in
                    if let range = filter.range(of: "=") {
                        let key = String(filter[..<range.lowerBound])
                        let value = String(filter[range.upperBound...])
                        return labels[key] == value
                    }
                    return labels[filter] != nil
                }
                if !matches {
                    return false
                }
            case "reference":
                let candidates = [reference, displayName].filter { !$0.isEmpty }
                if !values.contains(where: { filter in candidates.contains(where: { $0.contains(filter) }) }) {
                    return false
                }
            case "before":
                let matchesBefore = values.contains { target in
                    guard
                        let targetMetadata = imageMetadata[target]
                            ?? imageMetadata.first(where: { candidate, metadata in
                                candidate == target || candidate.hasPrefix(target) || metadata.name == target
                            })?.value
                    else {
                        return false
                    }
                    return createdAt < targetMetadata.created
                }
                if !matchesBefore {
                    return false
                }
            case "since":
                let matchesSince = values.contains { target in
                    guard
                        let targetMetadata = imageMetadata[target]
                            ?? imageMetadata.first(where: { candidate, metadata in
                                candidate == target || candidate.hasPrefix(target) || metadata.name == target
                            })?.value
                    else {
                        return false
                    }
                    return createdAt > targetMetadata.created
                }
                if !matchesSince {
                    return false
                }
            case "until":
                let matches = values.contains { value in
                    if let untilDate = DockerBuildFilterUtility.parseUntilFilter(value) {
                        let createdDate = Date(timeIntervalSince1970: TimeInterval(createdAt))
                        return createdDate < untilDate
                    }
                    return false
                }
                if !matches {
                    return false
                }
            default:
                continue
            }
        }

        _ = imagesInUse
        return true
    }

    private static func patchImageListJSON(_ object: inout Any) {
        guard var images = object as? [[String: Any]] else { return }

        for imageIndex in images.indices {
            var image = images[imageIndex]
            guard var manifests = image["Manifests"] as? [[String: Any]] else {
                images[imageIndex] = image
                continue
            }

            ImagePresentationUtility.patchUnavailableManifestContainers(in: &manifests)

            image["Manifests"] = manifests
            images[imageIndex] = image
        }

        object = images
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(ImageListQuery.self)
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }
            do {
                let filters = try DockerImageFilterUtility.parseImageListFilters(
                    filterParam: query.filters,
                    logger: req.logger
                )
                let images = try await client.list(includeSystemImages: query.all ?? false)
                let summaryImages = DockerImageReferenceResolver.summaryImages(from: images)
                let containers = try await ContainerClient().list()
                let includeManifests = query.manifests ?? false
                var imagesSummaries: [ImageSummary] = []
                let imagesInUse = Set(containers.map { $0.configuration.image.reference })
                var allDetails: [(image: ClientImage, details: ImageDetail)] = []
                var imageMetadata: [String: (created: Int64, name: String)] = [:]

                for image in summaryImages {
                    let details = try await image.details()
                    allDetails.append((image, details))
                    imageMetadata[image.reference] = (imageCreatedAt(details), details.name)
                    if !details.name.isEmpty {
                        imageMetadata[details.name] = (imageCreatedAt(details), details.name)
                    }
                }

                for (image, details) in allDetails {
                    if !matchesImageFilters(
                        image: image,
                        details: details,
                        filters: filters,
                        imagesInUse: imagesInUse,
                        imageMetadata: imageMetadata
                    ) {
                        continue
                    }
                    let imageIndex = try await image.index()
                    let manifests = imageIndex.manifests
                    var manifestSummaries: [ImageManifestSummary] = []
                    var created = 0
                    var size: Int64 = 0
                    var labels: [String: String] = [:]
                    var foundUsableManifest = false

                    for descriptor in manifests {
                        let isAttestation = descriptor.annotations?["vnd.docker.reference.type"] == "attestation-manifest"

                        guard let platform = descriptor.platform else {
                            continue
                        }

                        let available: Bool
                        let manifest: ContainerizationOCI.Manifest?
                        let config: ContainerizationOCI.Image?
                        if isAttestation {
                            manifest = nil
                            config = nil
                            available = false
                        } else {
                            do {
                                let resolvedConfig = try await image.config(for: platform)
                                let resolvedManifest = try await image.manifest(for: platform)
                                config = resolvedConfig
                                manifest = resolvedManifest
                                available = true
                            } catch {
                                config = nil
                                manifest = nil
                                available = false
                            }
                        }

                        let contentSize = (manifest?.config.size ?? 0) + (manifest?.layers.reduce(0) { $0 + $1.size } ?? 0)
                        let totalSize = descriptor.size + contentSize

                        if includeManifests {
                            let references = DockerImageReferenceResolver.references(
                                for: image,
                                allImages: images,
                                includeDigests: false
                            )
                            let knownReferences = Set(
                                references.repoTags + [image.reference] + (details.name.isEmpty ? [] : [details.name])
                            )

                            manifestSummaries.append(
                                ImagePresentationUtility.makeManifestSummary(
                                    descriptor: descriptor,
                                    parentDigest: details.index.digest,
                                    appSupportURL: appleContainerAppSupportUrl,
                                    available: available,
                                    manifest: manifest,
                                    kind: isAttestation ? .attestation : .image,
                                    containerIDs: available
                                        ? ImagePresentationUtility.manifestContainerIDs(
                                            imageDigest: image.digest,
                                            knownReferences: knownReferences,
                                            platform: platform,
                                            containers: containers
                                        ) : []
                                )
                            )
                        }

                        if !isAttestation, !foundUsableManifest, let config, available {
                            created = Int(AppleContainerTimestampResolver.unixTimestampSeconds(config.created))
                            size = totalSize
                            labels = config.config?.labels ?? [:]
                            foundUsableManifest = true
                        }
                    }

                    let references = DockerImageReferenceResolver.references(
                        for: image,
                        allImages: images,
                        // Docker still includes RepoDigests in image-list responses even
                        // when the `digests` query flag is not set.
                        includeDigests: true
                    )
                    let containersUsingImage = DockerImageReferenceResolver.containerUsageCount(
                        for: image,
                        containers: containers
                    )
                    // NOTE: Apple container does not expose per-layer sharing
                    // information, so SharedSize remains unset (-1).
                    let summary = ImageSummary(
                        id: image.digest,
                        parentId: "",
                        repoTags: references.repoTags,
                        repoDigests: references.repoDigests,
                        created: created,
                        size: size,
                        sharedSize: -1,
                        labels: labels,
                        containers: containersUsingImage,
                        manifests: includeManifests ? manifestSummaries : nil,
                        descriptor: ImagePresentationUtility.makeOCIDescriptor(
                            from: details.index,
                            appSupportURL: appleContainerAppSupportUrl
                        )
                    )

                    imagesSummaries.append(summary)
                }

                let encoded = try JSONEncoder().encode(imagesSummaries)
                var object = try JSONSerialization.jsonObject(with: encoded)
                patchImageListJSON(&object)
                return try ImageRouteUtility.jsonResponse(object)
            } catch {
                if let abort = error as? AbortError {
                    throw abort
                }
                throw Abort(.internalServerError, reason: "Failed to list images: \(error)")
            }
        }
    }
}
