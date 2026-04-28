import ContainerResource
import Vapor

struct VolumeInspectRoute: RouteCollection {
    let client: ClientVolumeService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/volumes/{name}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Volume {
        let name = try VolumeRouteUtility.requiredVolumeName(
            from: req,
            missingReason: "Missing volume name parameter"
        )
        do {
            return try await client.inspect(name: name)
        } catch {
            throw VolumeRouteUtility.mapInspectError(error, volumeName: name)
        }
    }
}
