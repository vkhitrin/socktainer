import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation

enum ImagePresentationUtility {
    static func makeOCIDescriptor(
        from descriptor: Descriptor,
        appSupportURL: URL? = nil,
        parentDigest: String? = nil
    ) -> OCIDescriptor {
        OCIPresentationUtility.makeDescriptor(
            from: descriptor,
            appSupportURL: appSupportURL,
            parentDigest: parentDigest,
            includeAppleExtras: true
        )
    }

    static func patchUnavailableManifestContainers(in manifests: inout [[String: Any]]) {
        for index in manifests.indices {
            var manifest = manifests[index]
            guard
                (manifest["Kind"] as? String) == "image",
                (manifest["Available"] as? Bool) == false,
                var imageData = manifest["ImageData"] as? [String: Any]
            else {
                continue
            }

            imageData["Containers"] = NSNull()
            manifest["ImageData"] = imageData
            manifests[index] = manifest
        }
    }

    static func manifestContainerIDs(
        imageDigest: String,
        knownReferences: Set<String>,
        platform: Platform,
        containers: [ContainerSnapshot]
    ) -> [String] {
        containers
            .filter {
                ($0.configuration.image.digest == imageDigest
                    || knownReferences.contains($0.configuration.image.reference)) && $0.platform == platform
            }
            .map(\.id)
            .sorted()
    }

    static func makeManifestSummary(
        descriptor: Descriptor,
        parentDigest: String,
        appSupportURL: URL,
        available: Bool,
        manifest: ContainerizationOCI.Manifest?,
        kind: ImageManifestSummary.Kind,
        containerIDs: [String]
    ) -> ImageManifestSummary {
        let contentSize = (manifest?.config.size ?? 0) + (manifest?.layers.reduce(0) { $0 + $1.size } ?? 0)
        let unpackedSize =
            kind == .image
            ? AppleContainerSnapshotResolver.unpackedSize(
                appSupportURL: appSupportURL,
                descriptor: descriptor
            ) : 0
        let totalSize = descriptor.size + contentSize + unpackedSize
        let platformSummary = descriptor.platform.map {
            OCIPlatform(
                architecture: $0.architecture,
                os: $0.os,
                osVersion: $0.osVersion,
                osFeatures: $0.osFeatures,
                variant: $0.variant
            )
        }

        return ImageManifestSummary(
            ID: descriptor.digest,
            descriptor: makeOCIDescriptor(
                from: descriptor,
                appSupportURL: appSupportURL,
                parentDigest: parentDigest
            ),
            available: available,
            size: .init(total: totalSize, content: contentSize),
            kind: kind,
            imageData: kind == .attestation
                ? nil
                : .init(
                    platform: platformSummary,
                    containers: containerIDs,
                    size: .init(unpacked: unpackedSize)
                ),
            attestationData: kind == .attestation
                ? descriptor.annotations?["vnd.docker.reference.digest"].map { .init(for: $0) }
                : nil
        )
    }
}
