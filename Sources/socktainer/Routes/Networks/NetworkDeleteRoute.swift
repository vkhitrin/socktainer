import ContainerizationError
import Vapor

struct NetworkDeletetRoute: RouteCollection {
    let client: ClientNetworkProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/networks/{id}", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let logger = req.logger
        guard let id = req.parameters.get("id") else {
            logger.warning("Missing network id parameter")
            throw Abort(.badRequest, reason: "Missing network id parameter")
        }

        if id == "default" {
            throw Abort(.forbidden, reason: "operation not supported for pre-defined networks")
        }

        do {
            let network = try await client.getNetwork(id: id, logger: logger)
            guard let network else {
                throw Abort(.notFound, reason: "No such network: \(id)")
            }
            try await client.delete(id: network.id ?? id, logger: logger)
            if let broadcaster = req.eventBroadcaster {
                let event = DockerEvent.simpleEvent(
                    id: network.id ?? id,
                    type: "network",
                    status: "remove",
                    from: network.name ?? id,
                    name: network.name ?? id,
                    labels: network.labels ?? [:]
                )
                await broadcaster.broadcast(event)
            } else {
                req.logger.warning("Event broadcaster not configured; skipping network remove event")
            }
            return Response(status: .noContent)
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            if let error = error as? ContainerizationError {
                switch error.code {
                case .notFound:
                    throw Abort(.notFound, reason: "No such network: \(id)")
                case .unsupported:
                    throw Abort(.forbidden, reason: error.message)
                default:
                    break
                }
            }
            if error.localizedDescription.contains("not found") {
                throw Abort(.notFound, reason: "No such network: \(id)")
            }
            throw Abort(.internalServerError, reason: "Network deletion failed: \(error)")
        }
    }
}
