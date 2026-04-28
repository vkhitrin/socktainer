import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

protocol ClientImageProtocol: Sendable {
    func list(includeSystemImages: Bool) async throws -> [ClientImage]
    func delete(id: String, force: Bool) async throws
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    >
    func push(
        imageName: String,
        tag: String?,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> AsyncThrowingStream<
        ClientImagePushEvent, Error
    >
    func prune(filters: [String: [String]], logger: Logger) async throws -> (deletedImages: [String], spaceReclaimed: Int64)
    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        importMessage: String?,
        importChanges: [String],
        logger: Logger
    ) async throws -> [String]
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL
}

extension ClientImageProtocol {
    func list() async throws -> [ClientImage] {
        try await list(includeSystemImages: false)
    }
}

enum ClientImageError: Error {
    case notFound(id: String)
    case inUse(id: String)
}

enum ClientImagePushEvent: Sendable, Hashable {
    case banner(String)
    case preparing(id: String)
    case unavailable(id: String)
    case pushing(id: String, current: Int64, total: Int64)
    case pushed(id: String)
}

struct ClientImageService: ClientImageProtocol {
    private struct PushBlobDescriptor {
        let id: String
        let size: Int64
    }

    private actor PushProgressMapper {
        private let descriptors: [PushBlobDescriptor]
        private var nextDescriptorIndex = 0
        private var currentDescriptorBytes: Int64 = 0
        private var completedDescriptorIDs = Set<String>()

        init(descriptors: [PushBlobDescriptor]) {
            self.descriptors = descriptors
        }

        func initialEvents() -> [ClientImagePushEvent] {
            descriptors.map { .preparing(id: $0.id) }
        }

        func events(for progressEvents: [ProgressUpdateEvent]) -> [ClientImagePushEvent] {
            var mapped: [ClientImagePushEvent] = []

            for event in progressEvents {
                switch event {
                case .addSize(let size), .setSize(let size):
                    guard size > 0 else {
                        continue
                    }
                    advanceToNextPendingDescriptor()
                    guard nextDescriptorIndex < descriptors.count else {
                        continue
                    }
                    let descriptor = descriptors[nextDescriptorIndex]
                    currentDescriptorBytes = min(descriptor.size, currentDescriptorBytes + size)
                    mapped.append(
                        .pushing(
                            id: descriptor.id,
                            current: currentDescriptorBytes,
                            total: descriptor.size
                        )
                    )
                case .addItems(let items), .setItems(let items):
                    guard items > 0 else {
                        continue
                    }
                    for _ in 0..<items {
                        advanceToNextPendingDescriptor()
                        guard nextDescriptorIndex < descriptors.count else {
                            break
                        }
                        let descriptor = descriptors[nextDescriptorIndex]
                        completedDescriptorIDs.insert(descriptor.id)
                        mapped.append(.pushed(id: descriptor.id))
                        nextDescriptorIndex += 1
                        currentDescriptorBytes = 0
                    }
                default:
                    continue
                }
            }

            return mapped
        }

        private func advanceToNextPendingDescriptor() {
            while nextDescriptorIndex < descriptors.count,
                completedDescriptorIDs.contains(descriptors[nextDescriptorIndex].id)
            {
                nextDescriptorIndex += 1
                currentDescriptorBytes = 0
            }
        }
    }

    private struct PushTarget {
        let reference: String
        let image: ClientImage
        let effectivePlatform: Platform?
        let descriptors: [PushBlobDescriptor]
    }

    private struct AvailableImageManifest {
        let platform: Platform
        let descriptorSize: Int64
        let manifest: Manifest
    }

    private func isAttestationManifestDescriptor(annotations: [String: String]?) -> Bool {
        annotations?["vnd.docker.reference.type"] == "attestation-manifest"
    }

    private func indexedPlatforms(for image: ClientImage) async throws -> [Platform] {
        try await image.index().manifests.compactMap { descriptor in
            guard !isAttestationManifestDescriptor(annotations: descriptor.annotations) else {
                return nil
            }
            return descriptor.platform
        }
    }

    private func availableImageManifests(
        for image: ClientImage,
        logger: Logger? = nil,
        unavailableManifestLogPrefix: String? = nil
    ) async throws -> [AvailableImageManifest] {
        let descriptors = try await image.index().manifests
        var collected: [AvailableImageManifest] = []

        for descriptor in descriptors {
            guard !isAttestationManifestDescriptor(annotations: descriptor.annotations) else {
                continue
            }
            guard let platform = descriptor.platform else {
                continue
            }

            do {
                let manifest = try await image.manifest(for: platform)
                collected.append(
                    AvailableImageManifest(
                        platform: platform,
                        descriptorSize: descriptor.size,
                        manifest: manifest
                    )
                )
            } catch {
                if let logger, let unavailableManifestLogPrefix {
                    logger.debug("\(unavailableManifestLogPrefix) \(platform.description) for \(image.reference): \(error)")
                }
            }
        }

        return collected
    }

    // Workaround for narrowing an unspecified push from all platforms to a single platform available.
    // This avoids container push failures caused by missing blobs for non local platforms.
    private func resolvedPushPlatform(for image: ClientImage, requestedPlatform: Platform?, logger: Logger) async throws -> Platform? {
        guard requestedPlatform == nil else {
            return requestedPlatform
        }

        let availablePlatforms = try await availableImageManifests(
            for: image,
            logger: logger,
            unavailableManifestLogPrefix: "Skipping unavailable platform"
        ).map(\.platform)

        if availablePlatforms.count == 1 {
            return availablePlatforms[0]
        }

        return nil
    }

    private func resolvedPushReference(imageName: String, tag: String?) throws -> String {
        guard let tag, !tag.isEmpty else {
            let parsedReference = try Reference.parse(imageName)
            let repositoryOnly = try Reference(
                path: parsedReference.path,
                domain: parsedReference.domain,
                tag: nil,
                digest: nil
            )
            return try ClientImage.normalizeReference(repositoryOnly.description)
        }

        let parsedReference = try Reference.parse(imageName)
        if tag.starts(with: "sha256:") {
            return try ClientImage.normalizeReference(try parsedReference.withDigest(tag).description)
        }
        return try ClientImage.normalizeReference(try parsedReference.withTag(tag).description)
    }

    private func normalizedRepositoryKey(for reference: String) throws -> String {
        let parsedReference = try Reference.parse(reference)
        if let domain = parsedReference.domain, !domain.isEmpty {
            return "\(domain)/\(parsedReference.path)"
        }
        return parsedReference.path
    }

    private func matchingPushReferences(imageName: String, logger: Logger) async throws -> [String] {
        let repositoryReference = try resolvedPushReference(imageName: imageName, tag: nil)
        let repositoryKey = try normalizedRepositoryKey(for: repositoryReference)
        let images = try await list(includeSystemImages: true)

        var references = Set<String>()
        for image in images {
            let reference = image.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reference.isEmpty, !reference.contains("@sha256:") else {
                continue
            }

            do {
                if try normalizedRepositoryKey(for: reference) == repositoryKey {
                    references.insert(reference)
                }
            } catch {
                logger.debug("Skipping unparsable image reference during push fanout: \(reference) (\(error))")
            }
        }

        return references.sorted()
    }

    private func pushTargets(
        imageName: String,
        tag: String?,
        platform: Platform?,
        logger: Logger
    ) async throws -> [PushTarget] {
        let references: [String]
        if let tag, !tag.isEmpty {
            references = [try resolvedPushReference(imageName: imageName, tag: tag)]
        } else {
            references = try await matchingPushReferences(imageName: imageName, logger: logger)
        }

        guard !references.isEmpty else {
            throw ClientImageError.notFound(id: try resolvedPushReference(imageName: imageName, tag: tag))
        }

        var targets: [PushTarget] = []
        targets.reserveCapacity(references.count)

        for reference in references {
            let image: ClientImage
            do {
                image = try await ClientImage.get(reference: reference)
            } catch {
                logger.error("Image not found: \(reference)")
                throw ClientImageError.notFound(id: reference)
            }

            let effectivePlatform = try await resolvedPushPlatform(
                for: image,
                requestedPlatform: platform,
                logger: logger
            )
            let descriptors = try await pushBlobDescriptors(for: image, platform: effectivePlatform)
            targets.append(
                PushTarget(
                    reference: reference,
                    image: image,
                    effectivePlatform: effectivePlatform,
                    descriptors: descriptors
                )
            )
        }

        return targets
    }

    func list(includeSystemImages: Bool = false) async throws -> [ClientImage] {
        let allImages = try await ClientImage.list()
        guard !includeSystemImages else {
            return allImages
        }
        // filter out infra images
        // also filter images based on digests
        let filteredImages = allImages.filter { img in
            let ref = img.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let isDigest = ref.contains("@sha256:")
            let isInfra = Utility.isInfraImage(name: ref)
            return isDigest || !isInfra
        }
        return filteredImages
    }

    func delete(id: String, force: Bool = false) async throws {
        let image: ClientImage
        do {
            image = try await ClientImage.get(reference: id)
        } catch {
            throw ClientImageError.notFound(id: id)
        }

        if !force {
            let containers = try await ContainerClient().list()
            let isInUse = containers.contains {
                $0.configuration.image.reference == image.reference || $0.configuration.image.reference == id
            }
            if isInUse {
                throw ClientImageError.inUse(id: id)
            }
        }
        try await ClientImage.delete(reference: id, garbageCollect: false)
    }

    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<
        String, Error
    > {
        let reference = try {
            let parsedReference = try Reference.parse(image)

            if parsedReference.digest != nil {
                // Docker ignores the separate `tag` parameter when the source reference is already
                // pinned by digest.
                return try ClientImage.normalizeReference(parsedReference.description)
            }

            guard let tag, !tag.isEmpty else {
                return try ClientImage.normalizeReference(image)
            }

            let updatedReference: Reference
            if tag.starts(with: "sha256:") {
                updatedReference = try parsedReference.withDigest(tag)
            } else {
                updatedReference = try parsedReference.withTag(tag)
            }
            return try ClientImage.normalizeReference(updatedReference.description)
        }()

        logger.info("Pulling image reference: \(reference)")

        return AsyncThrowingStream { continuation in
            logger.info("Starting to pull image \(reference) for platform \(platform.description)")
            continuation.yield("Trying to pull \(reference)")
            Swift.Task {
                do {
                    let image = try await ClientImage.pull(
                        reference: reference,
                        platform: platform,
                        progressUpdate: { progressEvents in
                            for event in progressEvents {
                                switch event {
                                case .setDescription(let description),
                                    .setSubDescription(let description),
                                    .setItemsName(let description),
                                    .custom(let description):
                                    continuation.yield(description)
                                case .addTotalSize(let size),
                                    .setTotalSize(let size),
                                    .addSize(let size),
                                    .setSize(let size):
                                    let humanReadableSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                                    continuation.yield("Downloaded \(humanReadableSize)")
                                case .addTotalItems(let items),
                                    .setTotalItems(let items),
                                    .addItems(let items),
                                    .setItems(let items):
                                    continuation.yield("Processing \(items) layer\(items == 1 ? "" : "s")")
                                default:
                                    break
                                }
                            }
                        }
                    )
                    continuation.yield("Unpacking image")
                    try await image.unpack(platform: platform, progressUpdate: nil)
                    logger.info("Successfully pulled image \(reference) for platform \(platform.description)")
                    continuation.yield("Image digest: \(image.digest)")
                    continuation.finish()
                } catch {
                    logger.error("Failed to pull image \(reference): \(error)")
                    continuation.yield(String(describing: error))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func push(
        imageName: String,
        tag: String?,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> AsyncThrowingStream<
        ClientImagePushEvent, Error
    > {
        let pushTargets = try await pushTargets(
            imageName: imageName,
            tag: tag,
            platform: platform,
            logger: logger
        )
        let repositoryName = try normalizedRepositoryKey(for: pushTargets[0].reference)
        let allDescriptors = Array(
            Dictionary(
                pushTargets
                    .flatMap(\.descriptors)
                    .map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            ).values
        )
        _ = appleContainerAppSupportUrl

        return AsyncThrowingStream { continuation in
            continuation.yield(ClientImagePushEvent.banner("The push refers to repository [\(repositoryName)]"))
            Swift.Task {
                do {
                    let progressMapper = PushProgressMapper(descriptors: allDescriptors)
                    for event in await progressMapper.initialEvents() {
                        continuation.yield(event)
                    }

                    for target in pushTargets.sorted(by: { $0.reference < $1.reference }) {
                        let pushPlatform = target.effectivePlatform
                        let progressHandler: ProgressUpdateHandler = { progressEvents in
                            for event in await progressMapper.events(for: progressEvents) {
                                continuation.yield(event)
                            }
                        }

                        let platformDesc = pushPlatform?.description ?? "default"
                        // Docker's omitted-tag push means "push all local tags for
                        // this repository". Keep that API contract, but execute the
                        // fanout as sequential native single-reference pushes. The
                        // shared multi-reference ImageStore push path is not
                        // reliable for our registry fixtures and returns backend
                        // transport failures even when single-tag push succeeds.
                        logger.info("Starting to push image \(target.reference) for platform \(platformDesc)")
                        try await target.image.push(
                            platform: pushPlatform,
                            scheme: .auto,
                            progressUpdate: progressHandler
                        )
                    }

                    logger.info("Successfully pushed image repository \(repositoryName)")
                    continuation.finish()
                } catch {
                    logger.error("Failed to push image repository \(repositoryName): \(error)")

                    // Check if this is a "notFound: Content with digest" error (missing layer data)
                    let errorDescription = String(describing: error)
                    if errorDescription.contains("notFound") && errorDescription.contains("Content with digest") {
                        let message =
                            "Failed to push image because one or more layers are missing from the image store. "
                            + "This is a known limitation of Apple's Containerization framework when working with tagged images. "
                            + "The tag metadata exists but the underlying layer data is not properly linked. Original error: \(errorDescription)"
                        logger.error("\(message)")
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func pushBlobDescriptors(for image: ClientImage, platform: Platform?) async throws -> [PushBlobDescriptor] {
        let manifests: [Manifest]
        if let platform {
            manifests = [try await image.manifest(for: platform)]
        } else {
            manifests = try await availableImageManifests(for: image).map(\.manifest)
        }

        var descriptors: [PushBlobDescriptor] = []
        var seenDigests = Set<String>()

        for manifest in manifests {
            let blobDescriptors = [manifest.config] + manifest.layers
            for descriptor in blobDescriptors {
                if seenDigests.insert(descriptor.digest).inserted {
                    descriptors.append(
                        PushBlobDescriptor(
                            id: shortPushID(for: descriptor.digest),
                            size: descriptor.size
                        )
                    )
                }
            }
        }

        return descriptors
    }

    private func shortPushID(for digest: String) -> String {
        let normalized: String
        if digest.hasPrefix("sha256:") {
            normalized = String(digest.dropFirst("sha256:".count))
        } else {
            normalized = digest
        }
        return String(normalized.prefix(12))
    }

    func prune(filters: [String: [String]], logger: Logger) async throws -> (deletedImages: [String], spaceReclaimed: Int64) {
        let allImages = try await list()
        var imagesToDelete: [ClientImage] = []

        let allContainers = try await ContainerClient().list()
        let imagesInUse = Set(allContainers.map { $0.configuration.image.reference })

        for image in allImages {
            var shouldDelete = false
            let reference = image.reference

            do {
                _ = try await image.details()

                if imagesInUse.contains(reference) {
                    continue
                }

                let isDangling = reference.contains("<none>") || reference.contains("@sha256:")

                if let danglingFilters = filters["dangling"], !danglingFilters.isEmpty {
                    shouldDelete = danglingFilters.contains { danglingValue in
                        let shouldBeDangling = (danglingValue == "true" || danglingValue == "1")
                        if shouldBeDangling {
                            return isDangling
                        }
                        return true
                    }
                } else {
                    shouldDelete = isDangling
                }

                var imageConfig: ContainerizationOCI.Image?
                if shouldDelete && (filters["label"] != nil || filters["until"] != nil) {
                    // Get the config for the first available platform
                    for platform in try await indexedPlatforms(for: image) {
                        do {
                            imageConfig = try await image.config(for: platform)
                            break
                        } catch {
                            continue
                        }
                    }
                }

                if shouldDelete, let labelFilters = filters["label"], let config = imageConfig {
                    var allLabelsMatch = true
                    for labelFilter in labelFilters {
                        if let eqIdx = labelFilter.firstIndex(of: "=") {
                            let key = String(labelFilter[..<eqIdx])
                            let value = String(labelFilter[labelFilter.index(after: eqIdx)...])
                            if config.config?.labels?[key] != value {
                                allLabelsMatch = false
                                break
                            }
                        } else {
                            if config.config?.labels?[labelFilter] == nil {
                                allLabelsMatch = false
                                break
                            }
                        }
                    }

                    shouldDelete = shouldDelete && allLabelsMatch
                }

                if shouldDelete, let untilFilters = filters["until"], let config = imageConfig {
                    let createdIso8601 = config.created ?? "1970-01-01T00:00:00Z"

                    let iso8601Formatter = ISO8601DateFormatter()
                    iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var imageCreationDate = iso8601Formatter.date(from: createdIso8601)

                    if imageCreationDate == nil {
                        iso8601Formatter.formatOptions = [.withInternetDateTime]
                        imageCreationDate = iso8601Formatter.date(from: createdIso8601)
                    }

                    if let imageCreationDate = imageCreationDate {
                        var matchesUntil = false

                        for untilValue in untilFilters {
                            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            var untilDate = iso8601Formatter.date(from: untilValue)

                            if untilDate == nil {
                                iso8601Formatter.formatOptions = [.withInternetDateTime]
                                untilDate = iso8601Formatter.date(from: untilValue)
                            }

                            if untilDate == nil {
                                if let unixTimestamp = TimeInterval(untilValue) {
                                    untilDate = Date(timeIntervalSince1970: unixTimestamp)
                                }
                            }

                            if let untilDate = untilDate {
                                if imageCreationDate < untilDate {
                                    matchesUntil = true
                                    break
                                }
                            } else {
                                logger.warning("Failed to parse until timestamp: \(untilValue)")
                            }
                        }

                        shouldDelete = shouldDelete && matchesUntil
                    } else {
                        logger.warning("Failed to parse image creation date: \(createdIso8601)")
                        shouldDelete = false
                    }
                }

            } catch {
                logger.warning("Failed to get details for image \(image.reference): \(error)")
                continue
            }

            if shouldDelete {
                imagesToDelete.append(image)
            }
        }

        var deletedImages: [String] = []
        var spaceReclaimed: Int64 = 0

        for image in imagesToDelete {
            do {
                let reference = image.reference
                for availableManifest in try await availableImageManifests(for: image) {
                    let manifest = availableManifest.manifest
                    // Calculate size: descriptor + config + all layers
                    let imageSize =
                        availableManifest.descriptorSize + manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
                    spaceReclaimed += imageSize
                }

                try await delete(id: reference, force: true)
                deletedImages.append(reference)
            } catch {
                logger.warning("Failed to delete image \(image.reference): \(error)")
            }
        }

        return (deletedImages, spaceReclaimed)
    }

    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        importMessage: String? = nil,
        importChanges: [String] = [],
        logger: Logger
    ) async throws -> [String] {
        let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let dockerFormatPath = tempDir.appendingPathComponent("docker-format")
        try FileManager.default.createDirectory(at: dockerFormatPath, withIntermediateDirectories: true)

        try ArchiveUtility.extract(tarPath: tarballPath, to: dockerFormatPath)

        let ociLayoutPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: ociLayoutPath, withIntermediateDirectories: true)

        let loadPath: URL
        let loadedImages: [String]
        if let existingOCILayout = ContainerImageUtility.findOCILayout(in: dockerFormatPath) {
            loadPath = existingOCILayout
            loadedImages = try ContainerImageUtility.imageReferences(in: existingOCILayout)
        } else {
            loadPath = ociLayoutPath
            loadedImages = try await ContainerImageUtility.convertDockerTarToOCI(
                dockerFormatPath: dockerFormatPath,
                ociLayoutPath: ociLayoutPath,
                logger: logger
            )
        }

        let effectivePlatform =
            try platform
            ?? ContainerImageUtility.inferredLoadPlatform(
                in: loadPath,
                preferredPlatform: currentPlatform(),
                logger: logger
            )

        if let effectivePlatform {
            // Apple's loader can require a single concrete platform even when
            // Docker accepts a multi-platform OCI archive with no explicit
            // platform query. Narrow the archive before handing it to Apple.
            try ContainerImageUtility.filterOCILayout(at: loadPath, for: effectivePlatform, logger: logger)
        }

        if (importMessage?.isEmpty == false) || !importChanges.isEmpty {
            try ContainerImageUtility.rewriteImportedImageMetadata(
                at: loadPath,
                message: importMessage,
                changes: importChanges,
                logger: logger
            )
        }

        let images = try await imageStore.load(
            from: loadPath,
            progress: { progressEvents in
                for event in progressEvents {
                    logger.debug("Load progress event: \(event.event) = \(event.value)")
                }
            })

        for image in loadedImages {
            logger.info("Loaded image: \(image)")
        }

        logger.info("Successfully loaded \(images.count) image(s) from tarball")

        return loadedImages
    }

    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        let imageStore = try ImageStore(path: appleContainerAppSupportUrl)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let exportPath = tempDir.appendingPathComponent("oci-layout")
        try FileManager.default.createDirectory(at: exportPath, withIntermediateDirectories: true)

        var resolvedRefs: [String] = []
        var inferredExportPlatform: Platform?

        for reference in references {
            do {
                let image = try await ClientImage.get(reference: reference)
                logger.debug("Image exists: \(image.reference)")
                resolvedRefs.append(image.reference)
                if platform == nil && references.count == 1 {
                    inferredExportPlatform = try await resolvedSavePlatform(for: image, logger: logger)
                }
            } catch {
                logger.error("Image not found: \(reference)")
                throw ClientImageError.notFound(id: reference)
            }
        }

        func isMissingBlobExportError(_ error: any Error) -> Bool {
            let errorDescription = String(describing: error)
            return errorDescription.contains("notFound")
                && errorDescription.localizedCaseInsensitiveContains("content with digest")
        }

        func exportImages() async throws {
            try await imageStore.save(
                references: resolvedRefs,
                out: exportPath,
                platform: platform
            )
        }

        func repullExportReferences() async throws {
            for resolvedRef in resolvedRefs {
                let image = try await ClientImage.get(reference: resolvedRef)
                let availablePlatforms = try await indexedPlatforms(for: image)
                let platformsToPull: [Platform?]
                if let platform {
                    platformsToPull = [platform]
                } else if !availablePlatforms.isEmpty {
                    platformsToPull = availablePlatforms.map(Optional.some)
                } else {
                    platformsToPull = [nil]
                }

                for platformToPull in platformsToPull {
                    logger.info("Re-pulling \(resolvedRef) for platform \(platformToPull?.description ?? "<default>") before retrying image export")
                    _ = try await ClientImage.pull(
                        reference: resolvedRef,
                        platform: platformToPull,
                        progressUpdate: nil
                    )
                }
            }
        }

        do {
            try await exportImages()
        } catch {
            let errorDescription = String(describing: error)
            logger.error("Failed to export images: \(errorDescription)")

            guard isMissingBlobExportError(error) else {
                throw error
            }

            // Apple can retain image metadata while evicting the blob content
            // required for save/export. Retry once after re-pulling through the
            // native image path instead of surfacing a false "No such image".
            try await repullExportReferences()

            do {
                try await exportImages()
            } catch {
                let retryErrorDescription = String(describing: error)
                logger.error("Failed to export images after re-pull: \(retryErrorDescription)")
                if isMissingBlobExportError(error) {
                    let detailedMessage =
                        "Export failed: ContentStore missing blob data. This is a limitation of Apple's Containerization framework. The image metadata exists but the underlying content blobs are not available."
                    logger.error("\(detailedMessage)")
                    throw ClientImageError.notFound(id: detailedMessage)
                }
                throw error
            }
        }

        if let selectedPlatform = platform ?? inferredExportPlatform {
            try ContainerImageUtility.pruneSavedOCILayout(
                at: exportPath,
                selectedPlatform: selectedPlatform,
                logger: logger
            )
        }

        let dockerManifests = try await ContainerImageUtility.convertOCIToDockerTar(
            ociLayoutPath: exportPath,
            dockerFormatPath: exportPath,
            resolvedRefs: resolvedRefs,
            selectedPlatform: platform ?? inferredExportPlatform,
            logger: logger
        )

        let dockerManifestData = try JSONSerialization.data(withJSONObject: dockerManifests, options: [.prettyPrinted])
        try dockerManifestData.write(to: exportPath.appendingPathComponent("manifest.json"))

        let tarballPath = tempDir.appendingPathComponent("images.tar")

        try ArchiveUtility.createImageTar(tarPath: tarballPath, from: exportPath)

        logger.info("Successfully exported \(references.count) image(s) to tarball in OCI layout with Docker manifest metadata")

        return tarballPath
    }

    private func resolvedSavePlatform(for image: ClientImage, logger: Logger) async throws -> Platform? {
        _ = logger
        return try await indexedPlatforms(for: image).first
    }
}
