import ContainerizationOCI
import CryptoKit
import Foundation
import Logging

enum ContainerImageUtility {

    enum Error: Swift.Error {
        case invalidTarball(reason: String)
        case invalidImportChange(reason: String)
    }

    private static var importHistoryTimestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func findOCILayout(in extractedPath: URL) -> URL? {
        let rootLayoutFile = extractedPath.appendingPathComponent("oci-layout")
        let rootIndexFile = extractedPath.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: rootLayoutFile.path),
            FileManager.default.fileExists(atPath: rootIndexFile.path)
        {
            return extractedPath
        }

        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: extractedPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let layoutFile = child.appendingPathComponent("oci-layout")
            let indexFile = child.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: layoutFile.path),
                FileManager.default.fileExists(atPath: indexFile.path)
            {
                return child
            }
        }

        return nil
    }

    static func imageReferences(in ociLayoutPath: URL) throws -> [String] {
        let dockerManifestURL = ociLayoutPath.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: dockerManifestURL.path) {
            let dockerManifestData = try FileIOUtility.readData(at: dockerManifestURL)
            let dockerManifests = try JSONDecoder().decode([TarManifest].self, from: dockerManifestData)
            let repoTags = dockerManifests.flatMap { $0.repoTags ?? [] }
            if !repoTags.isEmpty {
                return repoTags
            }
        }

        let indexURL = ociLayoutPath.appendingPathComponent("index.json")
        let data = try FileIOUtility.readData(at: indexURL)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let manifests = object["manifests"] as? [[String: Any]]
        else {
            return []
        }

        var references: [String] = []
        for manifest in manifests {
            if let annotations = manifest["annotations"] as? [String: String],
                let ref = annotations["org.opencontainers.image.ref.name"],
                !ref.isEmpty
            {
                references.append(ref)
                continue
            }

            if let digest = manifest["digest"] as? String, !digest.isEmpty {
                references.append(digest)
            }
        }

        return references
    }

    static func inferredLoadPlatform(
        in ociLayoutPath: URL,
        preferredPlatform: Platform,
        logger: Logger
    ) throws -> Platform? {
        let platforms = try loadPlatforms(fromDescriptorIndexAt: ociLayoutPath.appendingPathComponent("index.json"), root: ociLayoutPath)
        guard !platforms.isEmpty else {
            return nil
        }

        if let preferred = platforms.first(where: { descriptorMatchesPlatform($0, requestedPlatform: preferredPlatform) }) {
            return platform(from: preferred)
        }

        if let firstConcrete = platforms.first(where: {
            guard
                let platform = $0["platform"] as? [String: Any],
                let architecture = (platform["architecture"] as? String)?.lowercased(),
                let os = (platform["os"] as? String)?.lowercased()
            else {
                return false
            }
            return architecture != "unknown" && os != "unknown"
        }) {
            let inferred = platform(from: firstConcrete)
            logger.info("Inferred load platform \(inferred) from OCI archive")
            return inferred
        }

        return nil
    }

    static func filterOCILayout(at ociLayoutPath: URL, for platform: Platform, logger: Logger) throws {
        let indexURL = ociLayoutPath.appendingPathComponent("index.json")
        let indexData = try FileIOUtility.readData(at: indexURL)
        guard
            var indexObject = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
            let manifests = indexObject["manifests"] as? [[String: Any]]
        else {
            throw Error.invalidTarball(reason: "invalid OCI layout index")
        }

        let filteredManifests = try manifests.compactMap { descriptor in
            try filteredDescriptor(
                descriptor,
                ociLayoutPath: ociLayoutPath,
                requestedPlatform: platform,
                logger: logger
            )
        }

        guard !filteredManifests.isEmpty else {
            throw Error.invalidTarball(reason: "requested platform \(platform) not found in image archive")
        }

        indexObject["manifests"] = filteredManifests
        let filteredIndexData = try JSONSerialization.data(withJSONObject: indexObject, options: [.prettyPrinted])
        try filteredIndexData.write(to: indexURL)
    }

    private static func filteredDescriptor(
        _ descriptor: [String: Any],
        ociLayoutPath: URL,
        requestedPlatform: Platform,
        logger: Logger
    ) throws -> [String: Any]? {
        guard let mediaType = descriptor["mediaType"] as? String else {
            return descriptor
        }

        if mediaType == "application/vnd.oci.image.index.v1+json"
            || mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"
        {
            guard let digest = descriptor["digest"] as? String else {
                return nil
            }

            let nestedIndexURL =
                ociLayoutPath
                .appendingPathComponent("blobs/sha256")
                .appendingPathComponent(normalizedDigest(from: digest))
            let nestedIndexData = try FileIOUtility.readData(at: nestedIndexURL)
            guard
                var nestedIndexObject = try JSONSerialization.jsonObject(with: nestedIndexData) as? [String: Any],
                let nestedManifests = nestedIndexObject["manifests"] as? [[String: Any]]
            else {
                throw Error.invalidTarball(reason: "invalid nested OCI index: \(digest)")
            }

            let filteredNestedManifests = nestedManifests.filter {
                descriptorMatchesPlatform($0, requestedPlatform: requestedPlatform)
            }

            guard !filteredNestedManifests.isEmpty else {
                return nil
            }

            if filteredNestedManifests.count == nestedManifests.count {
                return descriptor
            }

            nestedIndexObject["manifests"] = filteredNestedManifests
            let filteredNestedIndexData = try JSONSerialization.data(
                withJSONObject: nestedIndexObject,
                options: [.prettyPrinted]
            )
            let filteredNestedDigest = filteredNestedIndexData.sha256Hex()
            let filteredNestedURL =
                ociLayoutPath
                .appendingPathComponent("blobs/sha256")
                .appendingPathComponent(filteredNestedDigest)
            try filteredNestedIndexData.write(to: filteredNestedURL)

            var filteredDescriptor = descriptor
            filteredDescriptor["digest"] = "sha256:\(filteredNestedDigest)"
            filteredDescriptor["size"] = filteredNestedIndexData.count
            logger.debug("Filtered OCI index \(digest) to platform \(requestedPlatform)")
            return filteredDescriptor
        }

        if descriptor["platform"] != nil {
            return descriptorMatchesPlatform(descriptor, requestedPlatform: requestedPlatform) ? descriptor : nil
        }

        return descriptor
    }

    private static func loadPlatforms(fromDescriptorIndexAt indexURL: URL, root: URL) throws -> [[String: Any]] {
        let data = try FileIOUtility.readData(at: indexURL)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let manifests = object["manifests"] as? [[String: Any]]
        else {
            throw Error.invalidTarball(reason: "invalid OCI layout index")
        }

        var collected: [[String: Any]] = []
        for descriptor in manifests {
            guard let mediaType = descriptor["mediaType"] as? String else {
                continue
            }

            if mediaType == "application/vnd.oci.image.index.v1+json"
                || mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"
            {
                guard let digest = descriptor["digest"] as? String else {
                    continue
                }
                let nestedURL =
                    root
                    .appendingPathComponent("blobs/sha256")
                    .appendingPathComponent(normalizedDigest(from: digest))
                collected.append(contentsOf: try loadPlatforms(fromDescriptorIndexAt: nestedURL, root: root))
                continue
            }

            if descriptor["platform"] != nil {
                collected.append(descriptor)
            }
        }

        return collected
    }

    private static func platform(from descriptor: [String: Any]) -> Platform {
        let platform = (descriptor["platform"] as? [String: Any]) ?? [:]
        let architecture = (platform["architecture"] as? String) ?? ""
        let os = (platform["os"] as? String) ?? ""
        let variant = platform["variant"] as? String
        return Platform(arch: architecture, os: os, variant: variant)
    }

    private static func descriptorMatchesPlatform(
        _ descriptor: [String: Any],
        requestedPlatform: Platform
    ) -> Bool {
        guard let platform = descriptor["platform"] as? [String: Any] else {
            return false
        }

        func normalized(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        let requestedOS = normalized(requestedPlatform.os)
        let requestedArchitecture = normalized(requestedPlatform.architecture)
        let requestedVariant = normalized(requestedPlatform.variant)

        let descriptorOS = normalized(platform["os"] as? String)
        let descriptorArchitecture = normalized(platform["architecture"] as? String)
        let descriptorVariant = normalized(platform["variant"] as? String)

        guard requestedOS == descriptorOS, requestedArchitecture == descriptorArchitecture else {
            return false
        }

        if let requestedVariant {
            return requestedVariant == descriptorVariant
        }

        return true
    }

    private static func normalizedDigest(from referencePath: String) -> String {
        let trimmed = referencePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sha256:") {
            return String(trimmed.dropFirst("sha256:".count))
        }
        if trimmed.hasSuffix(".json") {
            return URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        }
        if trimmed.hasSuffix("/layer.tar") {
            return URL(fileURLWithPath: trimmed).deletingLastPathComponent().lastPathComponent
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func resolveReferencedPath(root: URL, referencePath: String) -> URL? {
        let trimmed = referencePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let direct = root.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }

        let nestedOCI = root.appendingPathComponent("oci-layout").appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: nestedOCI.path) {
            return nestedOCI
        }

        let digestName = normalizedDigest(from: trimmed)
        let blobsCandidate = root.appendingPathComponent("blobs/sha256").appendingPathComponent(digestName)
        if FileManager.default.fileExists(atPath: blobsCandidate.path) {
            return blobsCandidate
        }

        let nestedBlobsCandidate = root.appendingPathComponent("oci-layout/blobs/sha256").appendingPathComponent(digestName)
        if FileManager.default.fileExists(atPath: nestedBlobsCandidate.path) {
            return nestedBlobsCandidate
        }

        return nil
    }

    static func convertDockerTarToOCI(
        dockerFormatPath: URL,
        ociLayoutPath: URL,
        logger: Logger
    ) async throws -> [String] {
        let manifestPath = dockerFormatPath.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestPath.path) else {
            throw Error.invalidTarball(reason: "manifest.json not found")
        }

        let manifestData = try FileIOUtility.readData(at: manifestPath)
        let dockerManifests = try JSONDecoder().decode([TarManifest].self, from: manifestData)

        let blobsDir = ociLayoutPath.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let ociLayout = "{\"imageLayoutVersion\": \"1.0.0\"}"
        try ociLayout.write(to: ociLayoutPath.appendingPathComponent("oci-layout"), atomically: true, encoding: .utf8)

        var indexManifests: [[String: Any]] = []
        var loadedImages: [String] = []

        for dockerManifest in dockerManifests {
            guard let configFile = dockerManifest.config,
                let layers = dockerManifest.layers
            else {
                continue
            }

            let configDigest = normalizedDigest(from: configFile)
            guard let configSrcPath = resolveReferencedPath(root: dockerFormatPath, referencePath: configFile) else {
                throw Error.invalidTarball(reason: "config blob not found: \(configFile)")
            }
            let configDstPath = blobsDir.appendingPathComponent(configDigest)

            if FileManager.default.fileExists(atPath: configSrcPath.path) {
                try FileManager.default.copyItem(at: configSrcPath, to: configDstPath)

                let configData = try FileIOUtility.readData(at: configDstPath)
                let configSize = configData.count
                let configRealDigest = configData.sha256Hex()

                if configRealDigest != configDigest {
                    logger.warning("Config digest mismatch: expected \(configDigest), got \(configRealDigest)")
                    let correctPath = blobsDir.appendingPathComponent(configRealDigest)
                    try FileManager.default.moveItem(at: configDstPath, to: correctPath)
                }

                var layerDescriptors: [[String: Any]] = []

                for layer in layers {
                    let layerDigest = normalizedDigest(from: layer)
                    guard let layerSrcPath = resolveReferencedPath(root: dockerFormatPath, referencePath: layer) else {
                        throw Error.invalidTarball(reason: "layer blob not found: \(layer)")
                    }
                    let layerDstPath = blobsDir.appendingPathComponent(layerDigest)

                    if FileManager.default.fileExists(atPath: layerSrcPath.path) {
                        try FileManager.default.copyItem(at: layerSrcPath, to: layerDstPath)

                        let layerData = try FileIOUtility.readData(at: layerDstPath)
                        let layerSize = layerData.count
                        let layerRealDigest = layerData.sha256Hex()

                        if layerRealDigest != layerDigest {
                            logger.warning("Layer digest mismatch: expected \(layerDigest), got \(layerRealDigest)")
                            let correctPath = blobsDir.appendingPathComponent(layerRealDigest)
                            try FileManager.default.moveItem(at: layerDstPath, to: correctPath)

                            layerDescriptors.append([
                                "mediaType": "application/vnd.oci.image.layer.v1.tar",
                                "digest": "sha256:\(layerRealDigest)",
                                "size": layerSize,
                            ])
                        } else {
                            layerDescriptors.append([
                                "mediaType": "application/vnd.oci.image.layer.v1.tar",
                                "digest": "sha256:\(layerDigest)",
                                "size": layerSize,
                            ])
                        }
                    }
                }

                let manifest: [String: Any] = [
                    "schemaVersion": 2,
                    "config": [
                        "mediaType": "application/vnd.oci.image.config.v1+json",
                        "digest": "sha256:\(configDigest)",
                        "size": configSize,
                    ],
                    "layers": layerDescriptors,
                ]

                let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [])
                let manifestDigest = manifestData.sha256Hex()
                let manifestPath = blobsDir.appendingPathComponent(manifestDigest)
                try manifestData.write(to: manifestPath)

                var manifestDescriptor: [String: Any] = [
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "digest": "sha256:\(manifestDigest)",
                    "size": manifestData.count,
                ]

                if let repoTags = dockerManifest.repoTags, let firstTag = repoTags.first {
                    manifestDescriptor["annotations"] = [
                        "org.opencontainers.image.ref.name": firstTag
                    ]
                }

                indexManifests.append(manifestDescriptor)
            }

            for repoTag in dockerManifest.repoTags ?? [] {
                loadedImages.append(repoTag)
            }
        }

        let index: [String: Any] = [
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": indexManifests,
        ]

        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted])
        try indexData.write(to: ociLayoutPath.appendingPathComponent("index.json"))

        logger.debug("Created OCI layout at \(ociLayoutPath.path)")
        logger.info("Index contains \(indexManifests.count) manifest(s)")

        if let indexString = String(data: indexData, encoding: .utf8) {
            logger.debug("Index JSON: \(indexString)")
        }

        return loadedImages
    }

    static func convertOCIToDockerTar(
        ociLayoutPath: URL,
        dockerFormatPath: URL,
        resolvedRefs: [String],
        selectedPlatform: Platform? = nil,
        logger: Logger
    ) async throws -> [[String: Any]] {
        let indexData = try FileIOUtility.readData(at: ociLayoutPath.appendingPathComponent("index.json"))
        let index = try JSONDecoder().decode(Index.self, from: indexData)

        var dockerManifests: [[String: Any]] = []

        for (idx, descriptor) in index.manifests.enumerated() {
            let descriptorDigest = descriptor.digest.replacingOccurrences(of: "sha256:", with: "")
            let blobPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(descriptorDigest)")
            let blobData = try FileIOUtility.readData(at: blobPath)

            if descriptor.mediaType == "application/vnd.oci.image.index.v1+json" {
                logger.debug("Found nested OCI index, processing manifests inside")
                let nestedIndex = try JSONDecoder().decode(Index.self, from: blobData)
                let selectedDigest = selectedPlatform.flatMap { platform in
                    nestedIndex.manifests.first(where: {
                        !isAttestationDescriptor($0.annotations)
                            && descriptorMatchesPlatformDictionary($0.platform, requestedPlatform: platform)
                    })?.digest
                }

                for nestedDescriptor in nestedIndex.manifests {
                    if let selectedDigest,
                        nestedDescriptor.digest != selectedDigest
                    {
                        continue
                    }
                    if isAttestationDescriptor(nestedDescriptor.annotations) {
                        continue
                    }
                    if nestedDescriptor.mediaType == "application/vnd.oci.image.manifest.v1+json" {
                        let manifest = try processOCIManifest(
                            descriptor: nestedDescriptor,
                            ociLayoutPath: ociLayoutPath,
                            dockerFormatPath: dockerFormatPath,
                            repoTag: idx < resolvedRefs.count ? resolvedRefs[idx] : "unknown:latest",
                            logger: logger
                        )
                        dockerManifests.append(manifest)
                    }
                }
            } else if descriptor.mediaType == "application/vnd.oci.image.manifest.v1+json" {
                if isAttestationDescriptor(descriptor.annotations) {
                    continue
                }
                let manifest = try processOCIManifest(
                    descriptor: descriptor,
                    ociLayoutPath: ociLayoutPath,
                    dockerFormatPath: dockerFormatPath,
                    repoTag: idx < resolvedRefs.count ? resolvedRefs[idx] : "unknown:latest",
                    logger: logger
                )
                dockerManifests.append(manifest)
            } else {
                logger.warning("Skipping descriptor with unknown mediaType: \(descriptor.mediaType)")
            }
        }

        return dockerManifests
    }

    static func pruneSavedOCILayout(
        at ociLayoutPath: URL,
        selectedPlatform: Platform?,
        logger: Logger
    ) throws {
        guard let selectedPlatform else {
            return
        }

        let indexData = try FileIOUtility.readData(at: ociLayoutPath.appendingPathComponent("index.json"))
        guard
            let indexObject = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
            let manifests = indexObject["manifests"] as? [[String: Any]]
        else {
            throw Error.invalidTarball(reason: "invalid OCI layout index")
        }
        let reachableDigests = try collectReachableDigests(
            from: manifests,
            ociLayoutPath: ociLayoutPath, selectedPlatform: selectedPlatform
        )
        let blobsPath = ociLayoutPath.appendingPathComponent("blobs/sha256")
        let blobEntries = try FileManager.default.contentsOfDirectory(
            at: blobsPath,
            includingPropertiesForKeys: nil
        )

        for blobURL in blobEntries {
            if !reachableDigests.contains(blobURL.lastPathComponent) {
                try FileManager.default.removeItem(at: blobURL)
            }
        }

        logger.info("Pruned OCI save layout to platform \(selectedPlatform.description) with \(reachableDigests.count) reachable blob(s)")
    }

    static func rewriteImportedImageMetadata(
        at ociLayoutPath: URL,
        message: String?,
        changes: [String],
        logger: Logger
    ) throws {
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmedMessage?.isEmpty == false) || !changes.isEmpty else {
            return
        }

        let indexURL = ociLayoutPath.appendingPathComponent("index.json")
        let indexData = try FileIOUtility.readData(at: indexURL)
        guard var indexObject = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
            let manifests = indexObject["manifests"] as? [[String: Any]]
        else {
            throw Error.invalidTarball(reason: "invalid OCI layout index")
        }

        indexObject["manifests"] = try manifests.map {
            try rewriteImportDescriptor(
                $0,
                ociLayoutPath: ociLayoutPath,
                message: trimmedMessage,
                changes: changes
            )
        }

        let updatedIndexData = try JSONSerialization.data(withJSONObject: indexObject, options: [.prettyPrinted])
        try updatedIndexData.write(to: indexURL)
        logger.info("Rewrote imported image metadata for \(manifests.count) manifest descriptor(s)")
    }

    private static func rewriteImportDescriptor(
        _ descriptor: [String: Any],
        ociLayoutPath: URL,
        message: String?,
        changes: [String]
    ) throws -> [String: Any] {
        guard let mediaType = descriptor["mediaType"] as? String,
            let digest = descriptor["digest"] as? String
        else {
            return descriptor
        }

        if mediaType == "application/vnd.oci.image.index.v1+json"
            || mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"
        {
            let nestedIndexURL =
                ociLayoutPath
                .appendingPathComponent("blobs/sha256")
                .appendingPathComponent(normalizedDigest(from: digest))
            let nestedIndexData = try FileIOUtility.readData(at: nestedIndexURL)
            guard var nestedIndexObject = try JSONSerialization.jsonObject(with: nestedIndexData) as? [String: Any],
                let nestedManifests = nestedIndexObject["manifests"] as? [[String: Any]]
            else {
                throw Error.invalidTarball(reason: "invalid nested OCI index: \(digest)")
            }

            nestedIndexObject["manifests"] = try nestedManifests.map {
                try rewriteImportDescriptor(
                    $0,
                    ociLayoutPath: ociLayoutPath,
                    message: message,
                    changes: changes
                )
            }

            let updatedNestedIndexData = try JSONSerialization.data(withJSONObject: nestedIndexObject, options: [.prettyPrinted])
            let updatedNestedDigest = updatedNestedIndexData.sha256Hex()
            try updatedNestedIndexData.write(
                to:
                    ociLayoutPath
                    .appendingPathComponent("blobs/sha256")
                    .appendingPathComponent(updatedNestedDigest)
            )

            var updatedDescriptor = descriptor
            updatedDescriptor["digest"] = "sha256:\(updatedNestedDigest)"
            updatedDescriptor["size"] = updatedNestedIndexData.count
            return updatedDescriptor
        }

        if mediaType == "application/vnd.oci.image.manifest.v1+json"
            || mediaType == "application/vnd.docker.distribution.manifest.v2+json"
        {
            return try rewriteImageManifestDescriptor(
                descriptor,
                ociLayoutPath: ociLayoutPath,
                message: message,
                changes: changes
            )
        }

        return descriptor
    }

    private static func collectReachableDigests(
        from descriptors: [[String: Any]],
        ociLayoutPath: URL,
        selectedPlatform: Platform?
    ) throws -> Set<String> {
        var reachable = Set<String>()
        for descriptor in descriptors {
            try collectReachableDigests(
                from: descriptor,
                ociLayoutPath: ociLayoutPath,
                selectedPlatform: selectedPlatform,
                reachable: &reachable
            )
        }
        return reachable
    }

    private static func collectReachableDigests(
        from descriptor: [String: Any],
        ociLayoutPath: URL,
        selectedPlatform: Platform?,
        reachable: inout Set<String>
    ) throws {
        guard
            let mediaType = descriptor["mediaType"] as? String,
            let digest = descriptor["digest"] as? String
        else {
            return
        }

        let normalized = normalizedDigest(from: digest)
        reachable.insert(normalized)

        let blobURL =
            ociLayoutPath
            .appendingPathComponent("blobs/sha256")
            .appendingPathComponent(normalized)

        if mediaType == "application/vnd.oci.image.index.v1+json"
            || mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"
        {
            let data = try FileIOUtility.readData(at: blobURL)
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let manifests = object["manifests"] as? [[String: Any]]
            else {
                throw Error.invalidTarball(reason: "invalid nested OCI index: \(digest)")
            }

            let selectedDigest = selectedPlatform.flatMap { platform in
                manifests.first(where: {
                    !isAttestationDescriptor($0["annotations"] as? [String: String])
                        && descriptorMatchesPlatform($0, requestedPlatform: platform)
                })?["digest"] as? String
            }

            for child in manifests {
                if let selectedDigest {
                    let childDigest = child["digest"] as? String
                    let childAnnotations = child["annotations"] as? [String: String]
                    let isLinkedAttestation =
                        isAttestationDescriptor(childAnnotations)
                        && childAnnotations?["vnd.docker.reference.digest"] == selectedDigest
                    if childDigest != selectedDigest && !isLinkedAttestation {
                        continue
                    }
                }
                try collectReachableDigests(
                    from: child,
                    ociLayoutPath: ociLayoutPath,
                    selectedPlatform: nil,
                    reachable: &reachable
                )
            }
            return
        }

        if mediaType == "application/vnd.oci.image.manifest.v1+json"
            || mediaType == "application/vnd.docker.distribution.manifest.v2+json"
        {
            let data = try FileIOUtility.readData(at: blobURL)
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let config = object["config"] as? [String: Any],
                let configDigest = config["digest"] as? String,
                let layers = object["layers"] as? [[String: Any]]
            else {
                throw Error.invalidTarball(reason: "invalid OCI image manifest: \(digest)")
            }
            reachable.insert(normalizedDigest(from: configDigest))
            for layer in layers {
                if let layerDigest = layer["digest"] as? String {
                    reachable.insert(normalizedDigest(from: layerDigest))
                }
            }
        }
    }

    private static func rewriteImageManifestDescriptor(
        _ descriptor: [String: Any],
        ociLayoutPath: URL,
        message: String?,
        changes: [String]
    ) throws -> [String: Any] {
        guard let manifestDigest = descriptor["digest"] as? String else {
            return descriptor
        }

        let manifestURL =
            ociLayoutPath
            .appendingPathComponent("blobs/sha256")
            .appendingPathComponent(normalizedDigest(from: manifestDigest))
        let manifestData = try FileIOUtility.readData(at: manifestURL)
        guard var manifestObject = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            var configDescriptor = manifestObject["config"] as? [String: Any],
            let configDigest = configDescriptor["digest"] as? String
        else {
            throw Error.invalidTarball(reason: "invalid OCI image manifest: \(manifestDigest)")
        }

        let configURL =
            ociLayoutPath
            .appendingPathComponent("blobs/sha256")
            .appendingPathComponent(normalizedDigest(from: configDigest))
        let configData = try FileIOUtility.readData(at: configURL)
        guard var configObject = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw Error.invalidTarball(reason: "invalid OCI image config: \(configDigest)")
        }

        try applyImportMetadata(to: &configObject, message: message, changes: changes)

        let updatedConfigData = try JSONSerialization.data(withJSONObject: configObject, options: [.prettyPrinted])
        let updatedConfigDigest = updatedConfigData.sha256Hex()
        try updatedConfigData.write(
            to:
                ociLayoutPath
                .appendingPathComponent("blobs/sha256")
                .appendingPathComponent(updatedConfigDigest)
        )

        configDescriptor["digest"] = "sha256:\(updatedConfigDigest)"
        configDescriptor["size"] = updatedConfigData.count
        manifestObject["config"] = configDescriptor

        let updatedManifestData = try JSONSerialization.data(withJSONObject: manifestObject, options: [])
        let updatedManifestDigest = updatedManifestData.sha256Hex()
        try updatedManifestData.write(
            to:
                ociLayoutPath
                .appendingPathComponent("blobs/sha256")
                .appendingPathComponent(updatedManifestDigest)
        )

        var updatedDescriptor = descriptor
        updatedDescriptor["digest"] = "sha256:\(updatedManifestDigest)"
        updatedDescriptor["size"] = updatedManifestData.count
        return updatedDescriptor
    }

    private static func applyImportMetadata(
        to configObject: inout [String: Any],
        message: String?,
        changes: [String]
    ) throws {
        var imageConfig = (configObject["config"] as? [String: Any]) ?? [:]
        var history = (configObject["history"] as? [[String: Any]]) ?? []

        if let message, !message.isEmpty {
            history.append([
                "created": importHistoryTimestamp,
                "created_by": "IMPORT",
                "comment": message,
                "empty_layer": true,
            ])
        }

        for rawChange in changes {
            try applyImportChange(rawChange, to: &imageConfig)
            history.append([
                "created": importHistoryTimestamp,
                "created_by": rawChange,
                "empty_layer": true,
            ])
        }

        configObject["config"] = imageConfig
        configObject["history"] = history
    }

    private static func processOCIManifest(
        descriptor: Descriptor,
        ociLayoutPath: URL,
        dockerFormatPath: URL,
        repoTag: String,
        logger: Logger
    ) throws -> [String: Any] {
        let prefersOCILayoutPaths = FileManager.default.fileExists(
            atPath: dockerFormatPath.appendingPathComponent("oci-layout").path
        )
        let manifestDigest = descriptor.digest.replacingOccurrences(of: "sha256:", with: "")
        let manifestPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(manifestDigest)")
        let manifestData = try FileIOUtility.readData(at: manifestPath)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)

        let configDigest = manifest.config.digest.replacingOccurrences(of: "sha256:", with: "")
        let configFileName = prefersOCILayoutPaths ? "blobs/sha256/\(configDigest)" : "\(configDigest).json"
        let configSrcPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(configDigest)")
        let configDstPath = dockerFormatPath.appendingPathComponent(configFileName)

        if !prefersOCILayoutPaths && !FileManager.default.fileExists(atPath: configDstPath.path) {
            try FileManager.default.copyItem(at: configSrcPath, to: configDstPath)
        }

        var layers: [String] = []
        for layer in manifest.layers {
            let layerDigest = layer.digest.replacingOccurrences(of: "sha256:", with: "")
            let layerFileName = prefersOCILayoutPaths ? "blobs/sha256/\(layerDigest)" : "\(layerDigest)/layer.tar"
            let layerDir = dockerFormatPath.appendingPathComponent(layerDigest)

            if !prefersOCILayoutPaths && !FileManager.default.fileExists(atPath: layerDir.path) {
                try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)

                let layerSrcPath = ociLayoutPath.appendingPathComponent("blobs/sha256/\(layerDigest)")
                let layerDstPath = layerDir.appendingPathComponent("layer.tar")
                try FileManager.default.copyItem(at: layerSrcPath, to: layerDstPath)
            }

            layers.append(layerFileName)
        }

        let displayRepoTag: String
        if let parsedReference = try? Reference.parse(repoTag),
            parsedReference.domain == "docker.io",
            parsedReference.path.hasPrefix("library/")
        {
            displayRepoTag =
                String(parsedReference.path.dropFirst("library/".count))
                + (parsedReference.tag.map { ":\($0)" } ?? "")
        } else {
            displayRepoTag = repoTag
        }

        return [
            "Config": configFileName,
            "RepoTags": [displayRepoTag],
            "Layers": layers,
        ]
    }

    private static func isAttestationDescriptor(_ annotations: [String: String]?) -> Bool {
        annotations?["vnd.docker.reference.type"] == "attestation-manifest"
    }

    private static func descriptorMatchesPlatformDictionary(_ descriptorPlatform: Platform?, requestedPlatform: Platform) -> Bool {
        descriptorPlatform == requestedPlatform
    }

    private static func applyImportChange(_ rawChange: String, to imageConfig: inout [String: Any]) throws {
        let trimmed = rawChange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let instruction = parts[0].uppercased()
        let arguments = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        switch instruction {
        case "CMD":
            imageConfig["Cmd"] = try parseCommandInstruction(arguments, instruction: instruction)
        case "ENTRYPOINT":
            imageConfig["Entrypoint"] = try parseCommandInstruction(arguments, instruction: instruction)
        case "SHELL":
            imageConfig["Shell"] = try parseJSONArray(arguments, instruction: instruction)
        case "ENV":
            let updates = try parseKeyValueAssignments(arguments, instruction: instruction)
            imageConfig["Env"] = mergeEnvironment(existing: imageConfig["Env"], updates: updates)
        case "LABEL":
            let updates = try parseKeyValueAssignments(arguments, instruction: instruction)
            imageConfig["Labels"] = mergeStringMap(existing: imageConfig["Labels"], updates: updates)
        case "EXPOSE":
            let ports = try parseTokenList(arguments, instruction: instruction)
            imageConfig["ExposedPorts"] = mergeSetMap(existing: imageConfig["ExposedPorts"], keys: ports)
        case "VOLUME":
            let volumes = try parseVolumeInstruction(arguments)
            imageConfig["Volumes"] = mergeSetMap(existing: imageConfig["Volumes"], keys: volumes)
        case "WORKDIR":
            guard !arguments.isEmpty else {
                throw Error.invalidImportChange(reason: "WORKDIR requires a path")
            }
            imageConfig["WorkingDir"] = arguments
        case "USER":
            guard !arguments.isEmpty else {
                throw Error.invalidImportChange(reason: "USER requires a value")
            }
            imageConfig["User"] = arguments
        case "STOPSIGNAL":
            guard !arguments.isEmpty else {
                throw Error.invalidImportChange(reason: "STOPSIGNAL requires a value")
            }
            imageConfig["StopSignal"] = arguments
        case "ONBUILD":
            guard !arguments.isEmpty else {
                throw Error.invalidImportChange(reason: "ONBUILD requires a trigger")
            }
            var onBuild = (imageConfig["OnBuild"] as? [String]) ?? []
            onBuild.append(arguments)
            imageConfig["OnBuild"] = onBuild
        default:
            // NOTE: socktainer can only rewrite the subset of import changes that
            // map cleanly onto OCI image config/history edits during Apple-backed
            // archive import. Full Docker import-change semantics would require a
            // richer image-build/frontend pipeline than the backend exposes here.
            throw Error.invalidImportChange(reason: "unsupported import change instruction: \(instruction)")
        }
    }

    private static func parseCommandInstruction(_ arguments: String, instruction: String) throws -> [String] {
        if arguments.hasPrefix("[") {
            return try parseJSONArray(arguments, instruction: instruction)
        }
        guard !arguments.isEmpty else {
            throw Error.invalidImportChange(reason: "\(instruction) requires a value")
        }
        return ["/bin/sh", "-c", arguments]
    }

    private static func parseJSONArray(_ arguments: String, instruction: String) throws -> [String] {
        guard let data = arguments.data(using: .utf8),
            let values = try JSONSerialization.jsonObject(with: data) as? [String]
        else {
            throw Error.invalidImportChange(reason: "\(instruction) requires a JSON string array")
        }
        return values
    }

    private static func parseTokenList(_ arguments: String, instruction: String) throws -> [String] {
        let tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            throw Error.invalidImportChange(reason: "\(instruction) requires at least one value")
        }
        return tokens
    }

    private static func parseVolumeInstruction(_ arguments: String) throws -> [String] {
        if arguments.hasPrefix("[") {
            return try parseJSONArray(arguments, instruction: "VOLUME")
        }
        return try parseTokenList(arguments, instruction: "VOLUME")
    }

    private static func parseKeyValueAssignments(_ arguments: String, instruction: String) throws -> [String: String] {
        let tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            throw Error.invalidImportChange(reason: "\(instruction) requires key=value assignments")
        }

        var updates: [String: String] = [:]
        for token in tokens {
            guard let separator = token.firstIndex(of: "=") else {
                throw Error.invalidImportChange(reason: "\(instruction) requires key=value assignments")
            }
            let key = String(token[..<separator])
            let value = String(token[token.index(after: separator)...])
            guard !key.isEmpty else {
                throw Error.invalidImportChange(reason: "\(instruction) requires non-empty keys")
            }
            updates[key] = value
        }
        return updates
    }

    private static func mergeEnvironment(existing: Any?, updates: [String: String]) -> [String] {
        var orderedKeys: [String] = []
        var values: [String: String] = [:]

        if let existing = existing as? [String] {
            for entry in existing {
                guard let separator = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<separator])
                let value = String(entry[entry.index(after: separator)...])
                if values[key] == nil {
                    orderedKeys.append(key)
                }
                values[key] = value
            }
        }

        for key in updates.keys.sorted() {
            if values[key] == nil {
                orderedKeys.append(key)
            }
            values[key] = updates[key]
        }

        return orderedKeys.compactMap { key in
            values[key].map { "\(key)=\($0)" }
        }
    }

    private static func mergeStringMap(existing: Any?, updates: [String: String]) -> [String: String] {
        var merged = (existing as? [String: String]) ?? [:]
        for (key, value) in updates {
            merged[key] = value
        }
        return merged
    }

    private static func mergeSetMap(existing: Any?, keys: [String]) -> [String: [String: String]] {
        var merged = (existing as? [String: [String: String]]) ?? [:]
        for key in keys {
            merged[key] = [:]
        }
        return merged
    }
}

extension Data {
    func sha256Hex() -> String {
        let hash = SHA256.hash(data: self)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
