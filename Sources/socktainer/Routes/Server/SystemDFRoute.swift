import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Vapor

struct SystemDFRoute: RouteCollection {
    let imageClient: ClientImageProtocol
    let containerClient: ClientContainerProtocol
    let volumeClient: ClientVolumeProtocol
    let builderClient: ClientBuilderProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/system/df", use: handler)
    }

    func handler(_ req: Request) async throws -> SystemDataUsageResponse {
        let query = try req.query.decode(SystemDataUsageQuery.self)
        let requestedTypes = Set(query.type ?? [])
        let supportedTypes: Set<String> = ["image", "container", "volume", "build-cache"]
        let unsupportedTypes = requestedTypes.subtracting(supportedTypes)
        if let unsupportedType = unsupportedTypes.sorted().first {
            throw Abort(.badRequest, reason: "Unsupported system df type filter: \(unsupportedType)")
        }
        let includeAll = requestedTypes.isEmpty

        async let images = imageClient.list(includeSystemImages: true)
        async let containers = containerClient.list(showAll: true, filters: [:])
        async let volumes = volumeClient.list(filters: nil, logger: req.logger)

        let (allImages, allContainers, allVolumes) = try await (images, containers, volumes)
        let containerCompletionByID: [String: StoppedContainerCompletion] =
            if let attachSessionManager = req.application.storage[StoppedContainerAttachSessionManagerKey.self] {
                await attachSessionManager.completions(containerIDs: allContainers.map(\.id))
            } else {
                [:]
            }
        let imageSummaries: [ImageSummary]?
        if includeAll || requestedTypes.contains("image") {
            imageSummaries = try await Self.buildImageSummaries(images: allImages, containers: allContainers)
        } else {
            imageSummaries = nil
        }

        let containerSummaries: [ContainerSummary]?
        if includeAll || requestedTypes.contains("container") {
            containerSummaries = try await Self.buildContainerSummaries(
                containers: allContainers,
                completionByID: containerCompletionByID
            )
        } else {
            containerSummaries = nil
        }

        let volumeSummaries: [Volume]?
        if includeAll || requestedTypes.contains("volume") {
            volumeSummaries = try await Self.buildVolumeSummaries(volumes: allVolumes, containers: allContainers)
        } else {
            volumeSummaries = nil
        }

        let layersSize: Int64?
        if includeAll || requestedTypes.contains("image") {
            let activeReferences = Set(allContainers.map(\.configuration.image.reference))
            let usage = try await ClientImage.calculateDiskUsage(activeReferences: activeReferences)
            layersSize = Int64(clamping: usage.totalSize)
        } else {
            layersSize = nil
        }

        let buildCache: [BuildCache]?
        if includeAll || requestedTypes.contains("build-cache") {
            do {
                buildCache = try await builderClient.diskUsage(logger: req.logger).map {
                    BuildCache(
                        ID: $0.id,
                        parents: $0.parents,
                        type: $0.kind.flatMap(BuildCache.ModelType.init(rawValue:)),
                        description: $0.description,
                        inUse: $0.inUse,
                        shared: $0.shared,
                        size: Int($0.size),
                        createdAt: $0.createdAt,
                        lastUsedAt: $0.lastUsedAt,
                        usageCount: $0.usageCount
                    )
                }
            } catch {
                // NOTE: BuildKit cache inspection depends on a reachable builder
                // daemon. Keep /system/df functional even when build-cache data
                // cannot be derived truthfully in the current environment.
                req.logger.warning("Falling back to empty build cache in /system/df: \(error)")
                buildCache = []
            }
        } else {
            buildCache = nil
        }

        return SystemDataUsageResponse(
            layersSize: layersSize,
            images: imageSummaries,
            containers: containerSummaries,
            volumes: volumeSummaries,
            buildCache: buildCache
        )
    }
}

extension SystemDFRoute {
    fileprivate struct ImageSummaryData {
        let image: ClientImage
        let created: Int
        let totalSize: Int64
        let labels: [String: String]
        let layerSizes: [String: Int64]
        let descriptor: OCIDescriptor
    }

    fileprivate static func buildImageSummaries(
        images: [ClientImage],
        containers: [ContainerSnapshot]
    ) async throws -> [ImageSummary] {
        let summaryImages = DockerImageReferenceResolver.summaryImages(from: images)
        let summaryData = try await withThrowingTaskGroup(of: ImageSummaryData.self) { group in
            for image in summaryImages {
                group.addTask {
                    let details = try await image.details()
                    let manifests = try await image.index().manifests
                    var created = 0
                    var totalSize: Int64 = 0
                    var labels: [String: String] = [:]
                    var layerSizes: [String: Int64] = [:]
                    var foundUsableManifest = false

                    for descriptor in manifests {
                        if descriptor.annotations?["vnd.docker.reference.type"] == "attestation-manifest" {
                            continue
                        }

                        let manifestSize: Int64
                        if let platform = descriptor.platform {
                            do {
                                let config = try await image.config(for: platform)
                                let manifest = try await image.manifest(for: platform)
                                manifestSize = descriptor.size + manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
                                totalSize += manifestSize
                                for layer in manifest.layers {
                                    layerSizes[layer.digest] = max(layerSizes[layer.digest] ?? 0, layer.size)
                                }
                                if !foundUsableManifest {
                                    created = Int(AppleContainerTimestampResolver.unixTimestampSeconds(config.created))
                                    labels = config.config?.labels ?? [:]
                                    foundUsableManifest = true
                                }
                                continue
                            } catch {
                            }
                        }

                        totalSize += descriptor.size
                    }

                    return ImageSummaryData(
                        image: image,
                        created: created,
                        totalSize: totalSize,
                        labels: labels,
                        layerSizes: layerSizes,
                        descriptor: OCIDescriptor(
                            mediaType: details.index.mediaType,
                            digest: details.index.digest,
                            size: details.index.size,
                            urls: details.index.urls,
                            annotations: details.index.annotations,
                            data: nil,
                            platform: details.index.platform.map {
                                OCIPlatform(
                                    architecture: $0.architecture,
                                    os: $0.os,
                                    osVersion: $0.osVersion,
                                    osFeatures: $0.osFeatures,
                                    variant: $0.variant
                                )
                            },
                            artifactType: nil
                        )
                    )
                }
            }

            var summaryData: [ImageSummaryData] = []
            for try await summary in group {
                summaryData.append(summary)
            }
            return summaryData
        }

        var layerImageCounts: [String: Int] = [:]
        for summary in summaryData {
            for layerDigest in summary.layerSizes.keys {
                layerImageCounts[layerDigest, default: 0] += 1
            }
        }

        let summaries = summaryData.map { summary -> ImageSummary in
            let references = DockerImageReferenceResolver.references(
                for: summary.image,
                allImages: images,
                includeDigests: true
            )
            let containerCount = DockerImageReferenceResolver.containerUsageCount(
                for: summary.image,
                containers: containers
            )
            let sharedSize = summary.layerSizes.reduce(into: Int64(0)) { total, entry in
                if (layerImageCounts[entry.key] ?? 0) > 1 {
                    total += entry.value
                }
            }

            return ImageSummary(
                id: summary.image.digest,
                parentId: "",
                repoTags: references.repoTags,
                repoDigests: references.repoDigests,
                created: summary.created,
                size: summary.totalSize,
                sharedSize: sharedSize,
                labels: summary.labels,
                containers: containerCount,
                manifests: nil,
                descriptor: summary.descriptor
            )
        }

        return summaries.sorted { $0.created > $1.created }
    }

    fileprivate static func buildContainerSummaries(
        containers: [ContainerSnapshot],
        completionByID: [String: StoppedContainerCompletion]
    ) async throws -> [ContainerSummary] {
        let containerClient = ContainerClient()
        return try await withThrowingTaskGroup(of: ContainerSummary.self) { group in
            for container in containers {
                group.addTask {
                    let size = try await containerClient.diskUsage(id: container.id)
                    return containerSummary(
                        from: container,
                        size: Int64(clamping: size),
                        completion: completionByID[container.id]
                    )
                }
            }

            var summaries: [ContainerSummary] = []
            for try await summary in group {
                summaries.append(summary)
            }
            return summaries.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        }
    }

    fileprivate static func buildVolumeSummaries(
        volumes: [Volume],
        containers: [ContainerSnapshot]
    ) async throws -> [Volume] {
        var refCounts: [String: Int64] = [:]
        for container in containers {
            for mount in container.configuration.mounts {
                if mount.isVolume, let name = mount.volumeName {
                    refCounts[name, default: 0] += 1
                }
            }
        }
        let normalizedRefCounts = refCounts

        return try await withThrowingTaskGroup(of: Volume.self) { group in
            for volume in volumes {
                group.addTask {
                    let size = try await ClientVolume.volumeDiskUsage(name: volume.name)
                    return Volume(
                        name: volume.name,
                        driver: volume.driver,
                        mountpoint: volume.mountpoint,
                        createdAt: volume.createdAt,
                        status: volume.status,
                        labels: volume.labels,
                        scope: volume.scope,
                        clusterVolume: volume.clusterVolume,
                        options: volume.options,
                        usageData: VolumeUsageData(
                            size: Int64(clamping: size),
                            refCount: normalizedRefCounts[volume.name] ?? 0
                        )
                    )
                }
            }

            var enrichedVolumes: [Volume] = []
            for try await volume in group {
                enrichedVolumes.append(volume)
            }
            return enrichedVolumes.sorted { $0.name < $1.name }
        }
    }

    fileprivate static func containerSummary(
        from container: ContainerSnapshot,
        size: Int64,
        completion: StoppedContainerCompletion?
    ) -> ContainerSummary {
        ContainerPresentationUtility.containerSummary(
            from: container,
            size: size,
            completion: completion,
            imageManifestDescriptor: nil
        )
    }
}
