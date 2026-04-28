import ContainerResource
import Vapor

struct VolumeDeleteRoute: RouteCollection {
    let client: ClientVolumeService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/volumes/{name}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let name = try VolumeRouteUtility.requiredVolumeName(from: req, missingReason: "Missing volume name")
        let query = try req.query.decode(VolumeDeleteQuery.self)
        _ = query.force
        do {
            let volume = try? await client.inspect(name: name)
            try await client.delete(name: name)
            if let broadcaster = req.eventBroadcaster {
                let event = DockerEvent.simpleEvent(
                    id: name,
                    type: "volume",
                    status: "destroy",
                    from: name,
                    name: name,
                    labels: volume?.labels ?? [:]
                )
                await broadcaster.broadcast(event)
            } else {
                req.logger.warning("Event broadcaster not configured; skipping volume destroy event")
            }
            return Response(status: .noContent)
        } catch {
            throw VolumeRouteUtility.mapDeleteError(error)
        }
    }
}
