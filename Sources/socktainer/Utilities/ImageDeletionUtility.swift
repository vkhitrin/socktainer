import ContainerAPIClient
import ContainerizationOCI
import Vapor

enum ImageDeletionUtility {
    static func deleteResponseItem(for imageRef: String) -> DockerImageDeleteResponseItem {
        if let parsedReference = try? Reference.parse(imageRef), parsedReference.tag != nil || parsedReference.digest != nil {
            return DockerImageDeleteResponseItem(untagged: imageRef, deleted: nil)
        }
        return DockerImageDeleteResponseItem(untagged: nil, deleted: imageRef)
    }

    static func deleteEventStatus(for imageRef: String) -> String {
        if let parsedReference = try? Reference.parse(imageRef), parsedReference.tag != nil || parsedReference.digest != nil {
            return "untag"
        }
        return "delete"
    }

    static func broadcastDeleteEvent(
        request: Request,
        resolvedImage: ClientImage?,
        imageRef: String,
        missingBroadcasterWarning: String
    ) async throws {
        guard let broadcaster = request.eventBroadcaster else {
            request.logger.warning("\(missingBroadcasterWarning)")
            return
        }

        let imageLabels = try? await resolvedImage?.config(for: currentPlatform()).config?.labels
        let event = DockerEvent.simpleEvent(
            id: resolvedImage?.digest ?? imageRef,
            type: "image",
            status: deleteEventStatus(for: imageRef),
            from: resolvedImage?.reference ?? imageRef,
            name: imageRef,
            image: resolvedImage?.reference ?? imageRef,
            labels: imageLabels ?? [:]
        )
        await broadcaster.broadcast(event)
    }
}
