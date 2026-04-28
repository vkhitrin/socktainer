import ContainerResource
import Vapor

struct ContainerStartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/start", use: ContainerStartRoute.handler(client: client))
    }
}

extension ContainerStartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerStartQuery.self)
            let detachKeys = query.detachKeys
            let attachSessionManager = req.application.storage[StoppedContainerAttachSessionManagerKey.self]
            let startedSessionManager = req.application.storage[StartedContainerSessionManagerKey.self]
            var eventContainer: ContainerSnapshot?

            do {
                guard let container = try await client.getContainer(id: id) else {
                    if let attachSessionManager {
                        let hasPreparedAttachSession = await attachSessionManager.session(containerID: id) != nil
                        let hasCompletedAttachSession = await attachSessionManager.completion(containerID: id) != nil
                        let hasPreparedOrCompletedAttachSession = hasPreparedAttachSession || hasCompletedAttachSession
                        if hasPreparedOrCompletedAttachSession {
                            req.logger.debug("Container \(id) already ran through a prepared attached session")
                            return Response(status: .noContent)
                        }
                    }
                    throw ContainerEventUtility.notFoundAbort(containerID: id)
                }
                eventContainer = container

                // If container is already running, return success (Docker CLI behavior)
                if container.status == .running {
                    req.logger.debug("Container \(id) is already running")
                    return Response(status: .notModified)
                } else {
                    let hasPreparedAttachSession =
                        if let attachSessionManager {
                            await attachSessionManager.session(containerID: container.id) != nil
                        } else {
                            false
                        }

                    // NOTE: When a stopped-container attach session was prepared
                    // earlier, socktainer starts that Apple-backed session here
                    // instead of going through a separate Docker daemon attach/start
                    // choreography. The observable behavior is close, but not a
                    // literal implementation of Moby's internal flow.
                    if hasPreparedAttachSession, let detachKeys, !detachKeys.isEmpty {
                        req.logger.debug("Ignoring custom start detachKeys '\(detachKeys)' for prepared attached session \(id)")
                    }

                    if let attachSessionManager, try await attachSessionManager.start(containerID: container.id) {
                        req.logger.debug("Started attached container session \(id)")
                    } else {
                        try await client.start(
                            id: id,
                            detachKeys: detachKeys,
                            startedSessionManager: startedSessionManager
                        )
                    }
                    req.logger.debug("Started container \(id)")
                }

            } catch {
                if let abort = error as? Abort {
                    throw abort
                }
                if let abort = error as? AbortError {
                    throw Abort(abort.status, reason: abort.reason)
                }

                // Check if error indicates container is already running/bootstrapped
                let errorMessage = error.localizedDescription
                let isAlreadyRunning =
                    errorMessage.contains("booted") || errorMessage.contains("expected to be in created state") || errorMessage.contains("invalidState")
                    || errorMessage.contains("already running")

                guard isAlreadyRunning else {
                    req.logger.error("Failed to start container \(id): \(error)")
                    throw Abort(.internalServerError, reason: "Failed to start container: \(error)")
                }
                req.logger.debug("Container \(id) was already running or bootstrapped")
            }

            await ContainerEventUtility.broadcastContainerEvent(
                request: req,
                status: "start",
                container: eventContainer,
                containerID: id
            )

            return Response(status: .noContent)
        }
    }
}
