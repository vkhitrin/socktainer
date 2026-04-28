import Vapor

public enum ContainerWaitCondition: String, CaseIterable, Codable, Sendable {
    case notRunning = "not-running"
    case nextExit = "next-exit"
    case removed = "removed"

    public static let `default`: ContainerWaitCondition = .notRunning
}

struct ContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/wait", use: ContainerWaitRoute.handler(client: client))
    }

    private static func waitResponse(
        req: Request,
        client: ClientContainerProtocol,
        containerID rawContainerId: String,
        condition: ContainerWaitCondition
    ) async throws -> ContainerWaitResponse {
        guard let container = try await client.getContainer(id: rawContainerId) else {
            throw Abort(.notFound, reason: "No such container: \(rawContainerId)")
        }

        if condition == .notRunning,
            let attachSessionManager = req.application.storage[StoppedContainerAttachSessionManagerKey.self]
        {
            let hasPreparedAttachSession = await attachSessionManager.session(containerID: container.id) != nil
            let hasCompletedAttachSession = await attachSessionManager.completion(containerID: container.id) != nil

            // Docker issues /wait immediately after /attach and before /start.
            // Allow the prepared attach session a short window to appear so
            // short-lived commands do not fall back to polling and hang.
            // NOTE: This prepared-session fast path is socktainer-specific
            // glue for the Apple-backed stopped-container attach flow, not
            // an exact replica of Docker daemon wait internals.
            if hasPreparedAttachSession || hasCompletedAttachSession {
                for _ in 0..<200 {
                    if let exitCode = await attachSessionManager.exitCodeIfAvailable(containerID: container.id) {
                        return ContainerWaitResponse(statusCode: exitCode)
                    }
                    if await attachSessionManager.hasStarted(containerID: container.id) {
                        let exitCode = await attachSessionManager.waitForExit(containerID: container.id)
                        if let exitCode {
                            return ContainerWaitResponse(statusCode: exitCode)
                        }
                    }
                    try await Swift.Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        let startedSessionManager = req.application.storage[StartedContainerSessionManagerKey.self]
        let waitResponse = try await client.wait(
            id: container.id,
            condition: condition,
            startedSessionManager: startedSessionManager
        )
        if condition == .notRunning,
            waitResponse.statusCode == 0,
            container.status == .stopped,
            let resolved = await AppleContainerExitStatusResolver.resolve(for: container)
        {
            return ContainerWaitResponse(statusCode: Int64(resolved.code))
        }
        return waitResponse
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let rawContainerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let conditionString = req.query["condition"] as String?
            let condition: ContainerWaitCondition

            if let conditionString = conditionString, !conditionString.isEmpty {
                guard let parsedCondition = ContainerWaitCondition(rawValue: conditionString) else {
                    throw Abort(.badRequest, reason: "invalid wait condition: \(conditionString)")
                }
                condition = parsedCondition
            } else {
                condition = ContainerWaitCondition.default
            }

            // Docker's client-side attach flow expects /wait to acknowledge the
            // request immediately and keep the body open until the exit status is
            // known. If we wait to compute the result before sending headers, the
            // CLI blocks inside ContainerWait() and never reaches /attach in time
            // for short-lived containers.
            guard try await client.getContainer(id: rawContainerId) != nil else {
                throw Abort(.notFound, reason: "No such container: \(rawContainerId)")
            }

            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            let body = Response.Body(stream: { writer in
                Swift.Task.detached {
                    defer { _ = writer.write(.end) }
                    // Vapor does not flush response headers for this streamed
                    // body until the first body write. Docker's client-side
                    // ContainerWait() call blocks until it observes response
                    // headers, so emit a harmless leading newline immediately
                    // to acknowledge the wait request before the container exits.
                    _ = writer.write(.buffer(ByteBuffer(string: "\n")))
                    do {
                        let response = try await waitResponse(
                            req: req,
                            client: client,
                            containerID: rawContainerId,
                            condition: condition
                        )
                        let data = try JSONEncoder().encode(response)
                        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        _ = writer.write(.buffer(buffer))
                    } catch {
                        let payload = ContainerWaitResponse(
                            statusCode: 255,
                            error: ContainerWaitExitError(message: "Failed to wait for container: \(error)")
                        )
                        if let data = try? JSONEncoder().encode(payload) {
                            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                            buffer.writeBytes(data)
                            _ = writer.write(.buffer(buffer))
                        }
                    }
                }
            })

            return Response(status: .ok, headers: headers, body: body)
        }
    }
}
