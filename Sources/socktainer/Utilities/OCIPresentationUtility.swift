import ContainerAPIClient
import ContainerizationOCI
import Foundation

enum OCIPresentationUtility {
    static func makeDescriptor(
        from descriptor: Descriptor,
        appSupportURL: URL? = nil,
        parentDigest: String? = nil,
        includeAppleExtras: Bool = false
    ) -> OCIDescriptor {
        let platform = descriptor.platform.map {
            OCIPlatform(
                architecture: $0.architecture,
                os: $0.os,
                osVersion: $0.osVersion,
                osFeatures: $0.osFeatures,
                variant: $0.variant
            )
        }

        let extras: AppleContainerImageStoreResolver.DescriptorExtras? =
            if let appSupportURL, let parentDigest {
                AppleContainerImageStoreResolver.descriptorExtras(
                    appSupportURL: appSupportURL,
                    parentDigest: parentDigest,
                    childDigest: descriptor.digest
                )
            } else {
                nil
            }
        let annotations =
            descriptor.annotations?.merging(extras?.annotations ?? [:]) { _, rawValue in rawValue }
            ?? extras?.annotations

        return OCIDescriptor(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            urls: descriptor.urls,
            annotations: annotations,
            data: includeAppleExtras ? extras?.data : nil,
            platform: platform,
            artifactType: includeAppleExtras ? extras?.artifactType : nil
        )
    }
}
