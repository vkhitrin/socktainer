import ContainerResource
import Vapor

struct VolumeUpdateRoute: RouteCollection {
    let client: ClientVolumeService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.PUT, pattern: "/volumes/{name}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        guard let name = req.parameters.get("name") else {
            throw Abort(.badRequest, reason: "Missing volume name")
        }

        // Docker reports swarm/cluster-volume unavailability before it enforces
        // the generated query/body contract here. Keep the request opaque and
        // return the same unsupported-path error instead of surfacing a decode
        // failure for missing cluster-only fields such as `version`.
        do {
            let volume = try await client.inspect(name: name)
            if volume.clusterVolume == nil {
                throw Abort(.serviceUnavailable, reason: "volume update only valid for cluster volumes, but swarm is unavailable")
            }

            throw Abort(.serviceUnavailable, reason: "Volume updates require swarm cluster volume support")
        } catch let abort as AbortError {
            throw abort
        } catch let error as VolumeError {
            switch error {
            case .volumeNotFound:
                throw Abort(.notFound, reason: error.localizedDescription)
            default:
                throw Abort(.internalServerError, reason: "Failed to update volume: \(error.localizedDescription)")
            }
        } catch {
            throw Abort(.internalServerError, reason: "Failed to update volume: \(error)")
        }
    }
}
