import ContainerAPIClient
import ContainerResource
import ContainerizationOCI

struct DockerImageReferences {
    let repoTags: [String]
    let repoDigests: [String]
}

enum DockerImageReferenceResolver {
    private static func displayReference(for image: ClientImage) -> String {
        (try? ClientImage.denormalizeReference(image.reference)) ?? image.reference
    }

    private static func syntheticDigestReference(for reference: String, digest: String) -> String? {
        guard !reference.contains("@sha256:") else {
            return reference
        }

        guard let parsed = try? Reference.parse(reference),
            let digested = try? parsed.withDigest(digest)
        else {
            return nil
        }

        return (try? ClientImage.denormalizeReference(digested.description)) ?? digested.description
    }

    static func references(
        for targetImage: ClientImage,
        allImages: [ClientImage],
        includeDigests: Bool
    ) -> DockerImageReferences {
        let matchingImages = allImages.filter { $0.digest == targetImage.digest }
        let candidates = matchingImages.isEmpty ? [targetImage] : matchingImages

        var repoTags = Set<String>()
        var repoDigests = Set<String>()

        for image in candidates {
            let reference = displayReference(for: image)
            guard !reference.isEmpty else { continue }

            if reference.contains("@sha256:") {
                if includeDigests {
                    repoDigests.insert(reference)
                }
            } else {
                repoTags.insert(reference)
                if includeDigests, let syntheticDigest = syntheticDigestReference(for: reference, digest: image.digest) {
                    // NOTE: Apple image references are often stored locally as tags
                    // without a parallel digest-qualified alias. Docker inspect
                    // still reports RepoDigests for those repositories, so derive
                    // the digest-qualified form from the known tag and image digest.
                    repoDigests.insert(syntheticDigest)
                }
            }
        }

        return DockerImageReferences(
            repoTags: repoTags.sorted(),
            repoDigests: includeDigests ? repoDigests.sorted() : []
        )
    }

    static func summaryImages(from images: [ClientImage]) -> [ClientImage] {
        var seenDigests = Set<String>()
        var summaries: [ClientImage] = []

        for image in images {
            if seenDigests.insert(image.digest).inserted {
                summaries.append(image)
            }
        }

        return summaries
    }

    static func containerUsageCount(
        for targetImage: ClientImage,
        containers: [ContainerSnapshot]
    ) -> Int {
        containers.filter {
            $0.configuration.image.digest == targetImage.digest
                || $0.configuration.image.reference == targetImage.reference
        }.count
    }
}
