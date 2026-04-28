import ContainerResource
import Vapor

enum ContainerEventUtility {
    static func notFoundAbort(containerID: String) -> Abort {
        Abort(.notFound, reason: "No such container: \(containerID)")
    }

    static func broadcastContainerEvent(
        request req: Request,
        status: String,
        container: ContainerSnapshot?,
        containerID: String,
        exitCode: String? = nil
    ) async {
        guard let broadcaster = req.eventBroadcaster else {
            req.logger.warning("Event broadcaster not configured; skipping container \(status) event")
            return
        }

        let event = DockerEvent.simpleEvent(
            id: containerID,
            type: "container",
            status: status,
            from: container?.configuration.image.reference ?? "",
            name: container?.configuration.labels[SocktainerContainerMetadata.containerNameLabel] ?? container?.id ?? containerID,
            image: container?.configuration.image.reference ?? "",
            exitCode: exitCode,
            labels: container.map { SocktainerContainerMetadata.userVisibleLabels(from: $0.configuration.labels) } ?? [:]
        )
        await broadcaster.broadcast(event)
    }
}
