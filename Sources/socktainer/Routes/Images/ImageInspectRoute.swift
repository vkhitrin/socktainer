import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Vapor

struct ImageInspectRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/json", use: ImageInspectRoute.handler(client: client))
    }
}

extension ImageInspectRoute {
    private static func defaultPlatform(from manifests: [Descriptor]) -> Platform? {
        manifests.first {
            $0.annotations?["vnd.docker.reference.type"] != "attestation-manifest"
                && $0.platform != nil
        }?.platform
    }

    private static func prioritizeVariants(
        _ variants: [ImageDetail.Variants],
        preferredPlatform: Platform? = nil
    ) -> [ImageDetail.Variants] {
        let preferredPlatform = requestedOrDefaultPlatform(preferredPlatform)

        return variants.enumerated().sorted { leftVariant, rightVariant in
            let leftPlatform = leftVariant.element.platform
            let rightPlatform = rightVariant.element.platform

            if preferredPlatformMatches(
                leftPlatform,
                over: rightPlatform,
                preferredPlatform: preferredPlatform
            ) {
                return true
            }

            return leftVariant.offset < rightVariant.offset
        }.map(\.element)
    }

    private static func patchImageInspectJSON(_ object: inout Any) {
        guard var image = object as? [String: Any] else { return }

        if var config = image["Config"] as? [String: Any] {
            if config["User"] == nil {
                config["User"] = ""
            }
            for key in ["Entrypoint", "Labels", "OnBuild", "Volumes"] where config[key] == nil {
                config[key] = NSNull()
            }
            image["Config"] = config
        }

        if var manifests = image["Manifests"] as? [[String: Any]] {
            ImagePresentationUtility.patchUnavailableManifestContainers(in: &manifests)
            image["Manifests"] = manifests
        }

        object = image
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let refOrId = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            let query = try req.query.decode(ImageInspectQuery.self)
            let requestedPlatform = try ImageRouteUtility.platformOrNil(query.platform)
            let includeManifests = (query.manifests ?? false) && requestedPlatform == nil
            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
            }

            _ = client

            let image = try await ImageRouteUtility.getImage(referenceOrID: refOrId)

            async let allImages = client.list(includeSystemImages: true)
            let containers = includeManifests ? try await ContainerClient().list() : []
            let details: ImageDetail = try await image.details()
            let imageIndex = try await image.index()
            let availableImages = try await allImages
            let manifests = imageIndex.manifests
            let availablePlatforms = Set(details.variants.map(\.platform))
            let preferredPlatform = requestedOrDefaultPlatform(requestedPlatform)
            var manifestSummaries: [ImageManifestSummary] = []

            for descriptor in manifests {
                let kind: String
                if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                    referenceType == "attestation-manifest"
                {
                    kind = "attestation"
                } else {
                    kind = "image"
                }

                let platform = descriptor.platform
                let manifest: ContainerizationOCI.Manifest?
                let available: Bool

                if let platform {
                    do {
                        manifest = try await image.manifest(for: platform)
                        available = availablePlatforms.contains(platform)
                    } catch {
                        manifest = nil
                        available = false
                    }
                } else {
                    manifest = nil
                    available = false
                }

                if includeManifests {
                    let knownReferences = Set(
                        [image.reference] + (details.name.isEmpty ? [] : [details.name])
                    )

                    manifestSummaries.append(
                        ImagePresentationUtility.makeManifestSummary(
                            descriptor: descriptor,
                            parentDigest: details.index.digest,
                            appSupportURL: appleContainerAppSupportUrl,
                            available: available,
                            manifest: manifest,
                            kind: kind == "attestation" ? .attestation : .image,
                            containerIDs: (available && platform != nil)
                                ? ImagePresentationUtility.manifestContainerIDs(
                                    imageDigest: image.digest,
                                    knownReferences: knownReferences,
                                    platform: platform!,
                                    containers: containers
                                ) : []
                        )
                    )
                }
            }

            let selectedVariant =
                if let requestedPlatform {
                    details.variants.first(where: { $0.platform == requestedPlatform })
                } else if let defaultPlatform = defaultPlatform(from: manifests) {
                    details.variants.first(where: { $0.platform == defaultPlatform })
                } else {
                    prioritizeVariants(details.variants, preferredPlatform: preferredPlatform).first
                }

            if let selectedVariant {
                let imageConfig: ImageConfig? = selectedVariant.config.config.map { ociConfig in
                    ImageConfig(
                        // Apple omits the image user when the config inherits the runtime
                        // default. Docker still serializes this as "", so preserve that
                        // value instead of dropping the key.
                        user: ociConfig.user ?? "",
                        exposedPorts: nil,
                        env: ociConfig.env,
                        cmd: ociConfig.cmd,
                        healthcheck: nil,
                        argsEscaped: nil,
                        volumes: nil,
                        workingDir: ociConfig.workingDir,
                        entrypoint: ociConfig.entrypoint,
                        onBuild: nil,
                        labels: ociConfig.labels,
                        stopSignal: ociConfig.stopSignal,
                        shell: nil
                    )
                }

                let selectedDescriptor = manifests.first { descriptor in
                    descriptor.platform == selectedVariant.platform
                        && descriptor.annotations?["vnd.docker.reference.type"] != "attestation-manifest"
                }

                let rootFS = ImageInspectRootFS(
                    type: selectedVariant.config.rootfs.type,
                    layers: selectedVariant.config.rootfs.diffIDs
                )
                let references = DockerImageReferenceResolver.references(
                    for: image,
                    allImages: availableImages,
                    includeDigests: true
                )
                // NOTE: Apple container does not persist legacy-builder metadata for
                // images. Docker's v1.51 schema allows DockerVersion to be an empty
                // string, so prefer "" over omitting the field entirely.

                let summary = ImageInspect(
                    // Docker reports the top-level image digest here, even when we
                    // select a concrete platform variant for the rest of the payload.
                    id: image.digest,
                    descriptor: ImagePresentationUtility.makeOCIDescriptor(
                        from: details.index,
                        appSupportURL: appleContainerAppSupportUrl
                    ),
                    manifests: includeManifests ? manifestSummaries : nil,
                    repoTags: references.repoTags,
                    repoDigests: references.repoDigests,
                    parent: "",
                    comment: selectedVariant.config.history?.last?.comment ?? "",
                    created: selectedVariant.config.created,
                    dockerVersion: "",
                    author: selectedVariant.config.author ?? "",
                    config: imageConfig,
                    architecture: selectedVariant.config.architecture,
                    variant: selectedVariant.config.variant,
                    os: selectedVariant.config.os,
                    osVersion: selectedVariant.config.osVersion,
                    size: selectedVariant.size,
                    graphDriver: selectedDescriptor.map {
                        AppleContainerImageStoreResolver.graphDriver(
                            appSupportURL: appleContainerAppSupportUrl,
                            descriptor: $0
                        )
                    } ?? nil,
                    rootFS: rootFS,
                    // Docker's schema allows Metadata.LastTagTime, but Apple's image
                    // reference store only persists `reference -> descriptor` in state.json.
                    // There is no authoritative per-tag timestamp to surface here, so
                    // we omit `Metadata.LastTagTime` instead of inventing a value.
                    metadata: .init(lastTagTime: nil)
                )

                let encoded = try JSONEncoder().encode(summary)
                var object = try JSONSerialization.jsonObject(with: encoded)
                patchImageInspectJSON(&object)
                return try ImageRouteUtility.jsonResponse(object)
            }

            if requestedPlatform != nil {
                throw Abort(.notFound, reason: "No such image: \(refOrId)")
            }

            throw Abort(.notFound, reason: "No such image: \(refOrId)")
        }
    }
}
