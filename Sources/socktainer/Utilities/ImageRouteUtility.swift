import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Vapor

enum ImageRouteUtility {
    static func platformOrNil(_ platformString: String?) throws -> Platform? {
        guard let platformString, !platformString.isEmpty else {
            return nil
        }

        return try platformOrThrow(platformString)
    }

    static func prioritizedManifests(_ manifests: [Descriptor], preferredPlatform: Platform?) -> [Descriptor] {
        guard let preferredPlatform else {
            return manifests
        }

        let primaryPlatform = requestedOrDefaultPlatform(preferredPlatform)

        return manifests.enumerated().sorted { leftManifest, rightManifest in
            let leftPlatform = leftManifest.element.platform
            let rightPlatform = rightManifest.element.platform

            if preferredPlatformMatches(
                leftPlatform,
                over: rightPlatform,
                preferredPlatform: primaryPlatform
            ) {
                return true
            }

            return leftManifest.offset < rightManifest.offset
        }.map(\.element)
    }

    static func jsonResponse(_ object: Any) throws -> Response {
        try JSONResponseUtility.response(object: object, contentType: "application/json")
    }

    static func getImage(referenceOrID: String) async throws -> ClientImage {
        do {
            return try await ClientImage.get(reference: referenceOrID)
        } catch {
            throw Abort(.notFound, reason: "No such image: \(referenceOrID)")
        }
    }
}
