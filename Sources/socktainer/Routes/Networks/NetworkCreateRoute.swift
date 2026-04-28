import ContainerizationError
import Vapor

struct NetworkCreateRoute: RouteCollection {
    let client: ClientNetworkProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/networks/create", use: self.handler)
    }

    private func abortForCreateError(_ error: any Error) -> Abort {
        if let abort = error as? Abort {
            return abort
        }
        if let abort = error as? AbortError {
            return Abort(abort.status, reason: abort.reason)
        }

        if let error = error as? ContainerizationError {
            switch error.code {
            case .invalidArgument:
                return Abort(.badRequest, reason: error.message)
            case .notFound:
                return Abort(.notFound, reason: error.message)
            case .unsupported:
                return Abort(.forbidden, reason: error.message)
            default:
                return Abort(.internalServerError, reason: "Failed to create network: \(error)")
            }
        }

        return Abort(.internalServerError, reason: "Failed to create network: \(error)")
    }

    func handler(_ req: Request) async throws -> Response {
        let logger = req.logger
        let query = try req.content.decode(NetworkCreateRequest.self)
        let name = query.name
        if name.isEmpty {
            throw Abort(.badRequest, reason: "Network name is required")
        }
        if name == "default" {
            throw Abort(.forbidden, reason: "operation not supported for pre-defined networks")
        }
        if let driver = query.driver, !driver.isEmpty, driver != "bridge" {
            throw Abort(.badRequest, reason: "Only the default bridge network driver is supported")
        }
        if let scope = query.scope, !scope.isEmpty, scope != "local" {
            throw Abort(.badRequest, reason: "Only local-scoped networks are supported")
        }
        if query.`internal` == true {
            throw Abort(.badRequest, reason: "Internal networks are not supported")
        }
        if query.attachable == true {
            throw Abort(.badRequest, reason: "Attachable networks are not supported")
        }
        if query.ingress == true {
            throw Abort(.badRequest, reason: "Ingress networks are not supported")
        }
        if query.configOnly == true {
            throw Abort(.badRequest, reason: "Config-only networks are not supported")
        }
        if query.configFrom != nil {
            throw Abort(.badRequest, reason: "ConfigFrom is not supported")
        }
        // Apple Container does not expose Docker IPAM controls. Ignore the
        // client-provided IPAM block instead of rejecting the request.
        if query.enableIPv4 == false {
            throw Abort(.badRequest, reason: "Disabling IPv4 is not supported")
        }
        if query.enableIPv6 == true {
            throw Abort(.badRequest, reason: "IPv6 networks are not supported")
        }
        if let options = query.options, !options.isEmpty {
            throw Abort(.badRequest, reason: "Custom network options are not supported")
        }
        // only pass network name and labels for now
        let labels = query.labels ?? [:]
        do {
            let response = try await client.create(name: name, labels: labels, logger: logger)
            if let broadcaster = req.eventBroadcaster {
                let event = DockerEvent.simpleEvent(
                    id: response.id,
                    type: "network",
                    status: "create",
                    from: name,
                    name: name,
                    labels: labels
                )
                await broadcaster.broadcast(event)
            } else {
                req.logger.warning("Event broadcaster not configured; skipping network create event")
            }
            return try await response.encodeResponse(status: .created, for: req)
        } catch {
            throw abortForCreateError(error)
        }
    }
}
