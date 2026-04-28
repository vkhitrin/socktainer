import ContainerAPIClient
import ContainerResource
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import Vapor

struct ContainerAttachRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/attach", use: ContainerAttachRoute.handler(client: client))
    }
}

extension ContainerAttachRoute {
    private static func stdioLogPath(for containerID: String, req: Request) -> String? {
        guard let appSupportURL = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
            return nil
        }

        let candidate =
            appSupportURL
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(containerID, isDirectory: true)
            .appendingPathComponent("stdio.log", isDirectory: false)

        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }

        return candidate.path
    }

    private struct EventNetworkContext {
        let id: String
        let name: String
        let type: String
    }

    private static func containerAutoRemove(_ container: ContainerSnapshot) -> Bool {
        ContainerLabelUtility.boolValue(
            container.configuration.labels[SocktainerContainerMetadata.autoRemoveLabel]
        ) == true
    }

    private static func containerOpenStdin(_ container: ContainerSnapshot) -> Bool {
        ContainerLabelUtility.boolValue(
            container.configuration.labels[SocktainerContainerMetadata.openStdinLabel]
        ) == true
    }

    private static func primaryNetworkIdentifier(for container: ContainerSnapshot) -> String? {
        if let network = container.networks.first?.network, !network.isEmpty {
            return network
        }
        if let network = container.configuration.networks.first?.network, !network.isEmpty {
            return network
        }
        return nil
    }

    private static func resolveEventNetworkContext(
        for container: ContainerSnapshot,
        logger: Logger
    ) async -> EventNetworkContext? {
        guard let identifier = primaryNetworkIdentifier(for: container) else {
            return nil
        }

        let service = ClientNetworkService()
        if let network = try? await service.getNetwork(id: identifier, logger: logger) {
            return EventNetworkContext(
                id: network.id ?? identifier,
                name: network.name ?? identifier,
                type: network.driver ?? "unknown"
            )
        }

        return EventNetworkContext(id: identifier, name: identifier, type: "unknown")
    }

    private static func networkLifecycleEvent(
        network: EventNetworkContext,
        action: String,
        containerID: String
    ) -> DockerEvent {
        DockerEvent.simpleEvent(
            id: network.id,
            type: "network",
            status: action,
            name: network.name,
            labels: [
                "container": containerID,
                "type": network.type,
            ]
        )
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            try await handleAttachRequest(req: req, client: client)
        }
    }

    private static func handleAttachRequest(req: Request, client: ClientContainerProtocol) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing container ID")
        }

        let query = try req.query.decode(ContainerAttachQuery.self)

        let logs = query.logs ?? false
        let stream = query.stream ?? false
        let stdout = query.stdout ?? false
        let stderr = query.stderr ?? false

        if let detachKeys = query.detachKeys, !detachKeys.isEmpty {
            req.logger.debug("Ignoring custom attach detachKeys '\(detachKeys)'")
        }

        // If no stdout/stderr specified, default to both (Docker behavior)
        guard stdout || stderr || (!stdout && !stderr) else {
            throw Abort(.badRequest, reason: "At least one of stdout or stderr must be true")
        }

        guard let container = try await client.getContainer(id: id) else {
            throw Abort(.notFound, reason: "No such container: \(id)")
        }

        // hijack connection
        let isUpgrade = req.headers.contains(where: { $0.name.lowercased() == "upgrade" && $0.value.lowercased() == "tcp" })
        let hasConnectionUpgrade = req.headers.contains(where: { $0.name.lowercased() == "connection" && $0.value.lowercased().contains("upgrade") })

        let isTTY = container.configuration.initProcess.terminal

        // For stopped containers, attach to the main process stdio directly.
        // This is required for short-lived commands, because polling logs after
        // process start is inherently racy and can miss their output entirely.
        if container.status == .stopped {
            return try await handleAttachToStoppedContainer(
                req: req,
                client: client,
                container: container,
                query: query,
                isUpgrade: isUpgrade,
                hasConnectionUpgrade: hasConnectionUpgrade,
                isTTY: isTTY
            )
        }

        // For running containers, Docker closes the attach response when the
        // caller requests historical logs only (`stream=0`). Treat that as a
        // bounded replay of currently available log output instead of entering
        // the live polling loop below, which would otherwise never finish for
        // long-running containers.
        if logs && !stream {
            return try await replayRunningContainerLogs(
                containerID: container.id,
                query: query,
                isTTY: isTTY,
                replayLogPath: stdioLogPath(for: container.id, req: req)
            )
        }

        // Docker's attach endpoint advertises the raw stream media type even when
        // the payload contains multiplexed frames for non-TTY containers.
        let contentType = "application/vnd.docker.raw-stream"

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)

        if isUpgrade && hasConnectionUpgrade {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
        }

        let replayLogPath = stdioLogPath(for: container.id, req: req)

        // NOTE: For already-running containers, Apple container does not expose a
        // Docker-compatible API to reattach directly to the init process stdio.
        // socktainer therefore falls back to host-side logs on this path. When
        // the combined `stdio.log` file exists, prefer tailing it over the live
        // log handles so attach does not leak Apple VM bootstrap stderr into the
        // user-visible stream.
        //
        // Apple persists only one merged stdio transcript here, so socktainer
        // cannot truthfully reconstruct Docker's separate stdout/stderr replay
        // channels from this backend data. The current behavior intentionally
        // favors "clean merged output" over "noisy but split output".
        // Create streaming response body using container logs when not using stdin
        let body = Response.Body { writer in
            Swift.Task.detached {
                let pollInterval: UInt64 = 200_000_000  // 200ms
                var containerWasRunning = false
                let wantStdout = stdout || (!stdout && !stderr)
                let wantStderr = stderr || (!stdout && !stderr)
                let mergedStreamType: DockerStreamFrame.StreamType = wantStdout ? .stdout : .stderr

                defer {
                    _ = writer.write(.end)
                }

                if let replayLogPath {
                    var offset = 0

                    while true {
                        let containerStatus: RuntimeStatus
                        do {
                            guard let currentContainer = try await client.getContainer(id: id) else {
                                break
                            }
                            containerStatus = currentContainer.status
                        } catch {
                            break
                        }

                        if containerStatus == .running {
                            containerWasRunning = true
                        }

                        if wantStdout || wantStderr,
                            let data = FileManager.default.contents(atPath: replayLogPath),
                            data.count > offset
                        {
                            let delta = data.subdata(in: offset..<data.count)
                            offset = data.count

                            let capacity = min(delta.count + (isTTY ? 0 : 8), 65536)
                            var buffer = sharedAllocator.buffer(capacity: capacity)
                            buffer.writeDockerFrame(streamType: mergedStreamType, data: delta, ttyMode: isTTY)
                            _ = writer.write(.buffer(buffer))
                        }

                        if containerStatus != .running {
                            if containerWasRunning {
                                break
                            }
                            try? await Swift.Task.sleep(nanoseconds: pollInterval)
                            continue
                        }

                        do {
                            try await Swift.Task.sleep(nanoseconds: pollInterval)
                        } catch {
                            break
                        }
                    }

                    return
                }

                // Continuously poll for log handles and send data
                while true {
                    // Check if container still exists and capture its current state.
                    let containerStatus: RuntimeStatus
                    do {
                        guard let currentContainer = try await client.getContainer(id: id) else {
                            break
                        }
                        containerStatus = currentContainer.status
                    } catch {
                        break
                    }

                    if containerStatus == .running {
                        containerWasRunning = true
                    }

                    var logHandles: [FileHandle] = []
                    var hasValidHandles = false

                    // Try to get log handles
                    do {
                        logHandles = try await ContainerClient().logs(id: container.id)
                        hasValidHandles = !logHandles.isEmpty
                    } catch {
                        hasValidHandles = false
                    }

                    defer {
                        for handle in logHandles {
                            try? handle.close()
                        }
                    }

                    if hasValidHandles {
                        var consecutiveEmptyReads = 0
                        let maxEmptyReads = 50  // Switch to polling after 100 empty reads
                        while true {
                            // Check if container still exists before reading data
                            let currentStatus: RuntimeStatus
                            do {
                                let currentContainer = try await client.getContainer(id: id)
                                guard let container = currentContainer else {
                                    return
                                }
                                currentStatus = container.status
                                if currentStatus == .running {
                                    containerWasRunning = true
                                }
                            } catch {
                                // Container not available, exit
                                return
                            }

                            var hasData = false

                            if wantStdout && logHandles.indices.contains(0) {
                                let stdoutData = logHandles[0].availableData
                                if !stdoutData.isEmpty {
                                    hasData = true
                                    let capacity = min(stdoutData.count + (isTTY ? 0 : 8), 65536)
                                    var buffer = sharedAllocator.buffer(capacity: capacity)
                                    buffer.writeDockerFrame(streamType: .stdout, data: stdoutData, ttyMode: isTTY)
                                    _ = writer.write(.buffer(buffer))
                                }
                            }

                            if wantStderr && logHandles.indices.contains(1) {
                                let stderrData = logHandles[1].availableData
                                if !stderrData.isEmpty {
                                    hasData = true
                                    let capacity = min(stderrData.count + (isTTY ? 0 : 8), 65536)
                                    var buffer = sharedAllocator.buffer(capacity: capacity)
                                    buffer.writeDockerFrame(streamType: .stderr, data: stderrData, ttyMode: isTTY)
                                    _ = writer.write(.buffer(buffer))
                                }
                            }

                            if !hasData {
                                if currentStatus != .running {
                                    // For short-lived commands we may never observe the
                                    // running state before their output is flushed.
                                    // Once the container is stopped and there is no more
                                    // data to send, close the attach stream.
                                    return
                                }

                                consecutiveEmptyReads += 1

                                // After many empty reads, send keep-alive less frequently
                                if consecutiveEmptyReads >= maxEmptyReads {
                                    consecutiveEmptyReads = 0  // Reset counter
                                    try await Swift.Task.sleep(nanoseconds: 500_000_000)  // 500ms
                                } else {
                                    try await Swift.Task.sleep(nanoseconds: 50_000_000)  // 50ms
                                }
                            } else {
                                consecutiveEmptyReads = 0
                                try await Swift.Task.sleep(nanoseconds: 5_000_000)  // 5ms when active
                            }
                        }

                    } else {
                        if containerWasRunning || containerStatus != .running {
                            break
                        }

                        // No valid handles, just wait
                        try await Swift.Task.sleep(nanoseconds: pollInterval)
                    }

                    do {
                        try await Swift.Task.sleep(nanoseconds: pollInterval)
                    } catch {
                        break
                    }
                }
            }
        }

        let status: HTTPResponseStatus = (isUpgrade && hasConnectionUpgrade) ? .switchingProtocols : .ok

        return Response(
            status: status,
            headers: headers,
            body: body
        )
    }

    private static func replayRunningContainerLogs(
        containerID: String,
        query: ContainerAttachQuery,
        isTTY: Bool,
        replayLogPath: String?
    ) async throws -> Response {
        let wantStdout = query.stdout ?? true
        let wantStderr = query.stderr ?? !isTTY
        let contentType = "application/vnd.docker.raw-stream"

        let body = Response.Body { writer in
            Swift.Task.detached {
                let idlePollLimit = 10
                let pollInterval: UInt64 = 50_000_000
                var stdoutOffset = 0
                var stderrOffset = 0
                var idlePolls = 0

                defer {
                    _ = writer.write(.end)
                }

                func emit(_ data: Data, streamType: DockerStreamFrame.StreamType) {
                    guard !data.isEmpty else {
                        return
                    }
                    let capacity = min(data.count + (isTTY ? 0 : 8), 65536)
                    var buffer = sharedAllocator.buffer(capacity: capacity)
                    buffer.writeDockerFrame(streamType: streamType, data: data, ttyMode: isTTY)
                    _ = writer.write(.buffer(buffer))
                }

                while idlePolls < idlePollLimit {
                    if let replayLogPath,
                        let data = FileManager.default.contents(atPath: replayLogPath),
                        data.count > stdoutOffset
                    {
                        let streamType: DockerStreamFrame.StreamType = wantStdout ? .stdout : .stderr
                        emit(data.subdata(in: stdoutOffset..<data.count), streamType: streamType)
                        stdoutOffset = data.count
                        idlePolls = 0
                        try? await Swift.Task.sleep(nanoseconds: pollInterval)
                        continue
                    }

                    let (stdoutHandle, stderrHandle) = openStoppedContainerLogHandles(containerID: containerID)
                    defer {
                        try? stdoutHandle?.close()
                        try? stderrHandle?.close()
                    }

                    var emittedData = false

                    if wantStdout,
                        let stdoutHandle,
                        let data = try? stdoutHandle.readToEnd(),
                        data.count > stdoutOffset
                    {
                        emit(data.subdata(in: stdoutOffset..<data.count), streamType: .stdout)
                        stdoutOffset = data.count
                        emittedData = true
                    }

                    if wantStderr,
                        let stderrHandle,
                        let data = try? stderrHandle.readToEnd(),
                        data.count > stderrOffset
                    {
                        emit(data.subdata(in: stderrOffset..<data.count), streamType: .stderr)
                        stderrOffset = data.count
                        emittedData = true
                    }

                    if emittedData {
                        idlePolls = 0
                    } else {
                        idlePolls += 1
                    }

                    if idlePolls < idlePollLimit {
                        try? await Swift.Task.sleep(nanoseconds: pollInterval)
                    }
                }
            }
        }

        return Response(
            status: .ok,
            headers: ["Content-Type": contentType],
            body: body
        )
    }

    private static func handleAttachToStoppedContainer(
        req: Request,
        client: ClientContainerProtocol,
        container: ContainerSnapshot,
        query: ContainerAttachQuery,
        isUpgrade: Bool,
        hasConnectionUpgrade: Bool,
        isTTY: Bool
    ) async throws -> Response {
        let connectionHeader = req.headers.first(name: "Connection")?.lowercased()
        let upgradeHeader = req.headers.first(name: "Upgrade")?.lowercased()
        let shouldUpgrade = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp"

        guard let currentContainer = try await client.getContainer(id: container.id) else {
            throw Abort(.notFound, reason: "No such container: \(container.id)")
        }

        // For stopped containers we need to control the main process stdio
        // ourselves, otherwise short-lived commands may exit before their
        // output becomes visible through the logs API.
        guard currentContainer.status == .stopped else {
            throw Abort(.internalServerError, reason: "Failed to attach stdin to container in \(currentContainer.status) state")
        }

        if !(query.logs ?? false) && !(query.stream ?? false) {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "application/vnd.docker.raw-stream")
            if isUpgrade || hasConnectionUpgrade {
                headers.replaceOrAdd(name: .connection, value: "Upgrade")
                headers.replaceOrAdd(name: .upgrade, value: "tcp")
                return Response(status: .switchingProtocols, headers: headers, body: .empty)
            }
            return Response(status: .ok, headers: headers, body: .empty)
        }

        if (query.logs ?? false) && !(query.stream ?? false) {
            return try await replayStoppedContainerLogs(
                container: currentContainer,
                query: query,
                isTTY: isTTY
            )
        }

        return try await createContainerForAttachment(
            req: req,
            client: client,
            container: currentContainer,
            query: query,
            shouldUpgrade: shouldUpgrade,
            isTTY: isTTY
        )
    }

    private static func replayStoppedContainerLogs(
        container: ContainerSnapshot,
        query: ContainerAttachQuery,
        isTTY: Bool
    ) async throws -> Response {
        let wantStdout = query.stdout ?? true
        let wantStderr = query.stderr ?? !isTTY
        let (stdoutHandle, stderrHandle) = openStoppedContainerLogHandles(containerID: container.id)

        let contentType = "application/vnd.docker.raw-stream"
        let body = Response.Body { writer in
            Swift.Task.detached {
                defer {
                    try? stdoutHandle?.close()
                    try? stderrHandle?.close()
                    _ = writer.write(.end)
                }

                func writeLogData(_ data: Data, streamType: DockerStreamFrame.StreamType) {
                    guard !data.isEmpty else { return }
                    let capacity = min(data.count + (isTTY ? 0 : 8), 65536)
                    var buffer = sharedAllocator.buffer(capacity: capacity)
                    buffer.writeDockerFrame(streamType: streamType, data: data, ttyMode: isTTY)
                    _ = writer.write(.buffer(buffer))
                }

                if wantStdout, let stdoutHandle, let data = try? stdoutHandle.readToEnd() {
                    writeLogData(data, streamType: .stdout)
                }

                if wantStderr, let stderrHandle, let data = try? stderrHandle.readToEnd() {
                    writeLogData(data, streamType: .stderr)
                }
            }
        }

        return Response(
            status: .ok,
            headers: ["Content-Type": contentType],
            body: body
        )
    }

    private static func openStoppedContainerLogHandles(containerID: String) -> (FileHandle?, FileHandle?) {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.apple.container/containers", isDirectory: true)
        let bundle = ContainerResource.Bundle(path: root.appendingPathComponent(containerID, isDirectory: true))
        let fileManager = FileManager.default

        // Apple's logs API fails if either log file is missing. For never-started
        // containers there may be no stdio.log yet, so attach+logs should degrade
        // to an empty replay instead of surfacing that Apple backend limitation as
        // a 500 from Docker's attach route.
        let stdoutHandle =
            fileManager.fileExists(atPath: bundle.containerLog.path)
            ? try? FileHandle(forReadingFrom: bundle.containerLog)
            : nil
        let stderrHandle =
            fileManager.fileExists(atPath: bundle.bootlog.path)
            ? try? FileHandle(forReadingFrom: bundle.bootlog)
            : nil

        return (stdoutHandle, stderrHandle)
    }

    // Handle attachment to stopped containers by bootstrapping with our stdio
    private static func createContainerForAttachment(
        req: Request,
        client: ClientContainerProtocol,
        container: ContainerSnapshot,
        query: ContainerAttachQuery,
        shouldUpgrade: Bool,
        isTTY: Bool
    ) async throws -> Response {
        guard let attachSessionManager = req.application.storage[StoppedContainerAttachSessionManagerKey.self] else {
            throw Abort(.internalServerError, reason: "Stopped container attach session manager not configured")
        }

        let attachStdin = (query.stdin ?? false) && containerOpenStdin(container)
        let attachStdout = query.stdout ?? true
        let attachStderr = query.stderr ?? !isTTY
        let shouldAutoStart = query.stream ?? false

        // Create pipes for bidirectional communication with the main process
        let stdinPipe: Pipe? = attachStdin ? Pipe() : nil
        let stdoutPipe: Pipe? = attachStdout ? Pipe() : nil
        let stderrPipe: Pipe? = (attachStderr && !isTTY) ? Pipe() : nil

        let stdio = [
            stdinPipe?.fileHandleForReading,
            stdoutPipe?.fileHandleForWriting,
            stderrPipe?.fileHandleForWriting,
        ]

        let process: ClientProcess
        do {
            process = try await ContainerClient().bootstrap(id: container.id, stdio: stdio)
        } catch {
            throw Abort(.internalServerError, reason: "Failed to bootstrap container: \(error.localizedDescription)")
        }

        let session = await attachSessionManager.prepare(
            containerID: container.id,
            runtime: container.configuration.runtimeHandler,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )

        if shouldAutoStart, let broadcaster = req.eventBroadcaster {
            let eventLabels = SocktainerContainerMetadata.userVisibleLabels(from: container.configuration.labels)
            let containerName = container.configuration.labels[SocktainerContainerMetadata.containerNameLabel] ?? container.id
            let networkContext = await resolveEventNetworkContext(for: container, logger: req.logger)

            await broadcaster.broadcast(
                DockerEvent.simpleEvent(
                    id: container.id,
                    type: "container",
                    status: "attach",
                    from: container.configuration.image.reference,
                    name: containerName,
                    image: container.configuration.image.reference,
                    labels: eventLabels
                )
            )
            if let networkContext {
                await broadcaster.broadcast(
                    networkLifecycleEvent(
                        network: networkContext,
                        action: "connect",
                        containerID: container.id
                    )
                )
            }
            await broadcaster.broadcast(
                DockerEvent.simpleEvent(
                    id: container.id,
                    type: "container",
                    status: "start",
                    from: container.configuration.image.reference,
                    name: containerName,
                    image: container.configuration.image.reference,
                    labels: eventLabels
                )
            )
        }

        guard shouldUpgrade else {
            return DockerPlainStreamingResponse.create(
                request: req,
                ttyEnabled: isTTY,
                nonTTYContentType: "application/vnd.docker.raw-stream"
            ) { streamContinuation in
                DockerStreamRuntime.installReadabilityHandler(
                    on: stdoutPipe?.fileHandleForReading,
                    streamType: .stdout,
                    tty: isTTY,
                    allocator: sharedAllocator,
                    onChunk: { streamContinuation.yield($0) },
                    onEOF: {}
                )

                DockerStreamRuntime.installReadabilityHandler(
                    on: stderrPipe?.fileHandleForReading,
                    streamType: .stderr,
                    tty: isTTY,
                    allocator: sharedAllocator,
                    onChunk: { streamContinuation.yield($0) },
                    onEOF: {}
                )

                await withTaskGroup(of: Void.self) { group in
                    let autoStartBeganAt = shouldAutoStart ? Date() : nil
                    let networkContext = shouldAutoStart ? await resolveEventNetworkContext(for: container, logger: req.logger) : nil

                    group.addTask {
                        guard shouldAutoStart else {
                            return
                        }
                        do {
                            try await attachSessionManager.start(containerID: container.id)
                        } catch {
                            streamContinuation.finish(throwing: error)
                        }
                    }

                    group.addTask {
                        defer {
                            session.closeClientHandles()
                            Swift.Task {
                                await attachSessionManager.remove(containerID: container.id)
                            }
                            streamContinuation.finish()
                        }

                        let exitCode = await session.waitForExit()
                        await attachSessionManager.markCompleted(containerID: container.id, exitCode: exitCode)
                        if let broadcaster = req.eventBroadcaster {
                            let eventLabels = SocktainerContainerMetadata.userVisibleLabels(from: container.configuration.labels)
                            let containerName = container.configuration.labels[SocktainerContainerMetadata.containerNameLabel] ?? container.id
                            var dieLabels = eventLabels
                            if let autoStartBeganAt {
                                dieLabels["execDuration"] = String(max(0, Int(Date().timeIntervalSince(autoStartBeganAt))))
                            }
                            if containerAutoRemove(container), let networkContext {
                                await broadcaster.broadcast(
                                    networkLifecycleEvent(
                                        network: networkContext,
                                        action: "disconnect",
                                        containerID: container.id
                                    )
                                )
                            }
                            let event = DockerEvent.simpleEvent(
                                id: container.id,
                                type: "container",
                                status: "die",
                                from: container.configuration.image.reference,
                                name: containerName,
                                image: container.configuration.image.reference,
                                exitCode: String(exitCode),
                                labels: dieLabels
                            )
                            await broadcaster.broadcast(event)
                            if containerAutoRemove(container) {
                                await broadcaster.broadcast(
                                    DockerEvent.simpleEvent(
                                        id: container.id,
                                        type: "container",
                                        status: "destroy",
                                        from: container.configuration.image.reference,
                                        name: containerName,
                                        image: container.configuration.image.reference,
                                        labels: eventLabels
                                    )
                                )
                            }
                        }

                        DockerStreamRuntime.emitTrailingOutput(
                            stdout: session.stdoutReader,
                            stderr: session.stderrReader,
                            tty: isTTY,
                            emit: { streamContinuation.yield($0) }
                        )
                    }

                    if let stdinWriter = session.stdinWriter {
                        group.addTask {
                            await DockerStreamRuntime.forwardBody(req.body, to: stdinWriter)
                        }
                    }

                    for await _ in group {}
                }
            }
        }

        return Response.dockerRawStreamUpgrade(
            ttyEnabled: isTTY
        ) { channel, tcpHandler in
            let writeState = DockerUpgradeWriteState()
            let closeState = DockerUpgradeCloseState(configuredStreams: [session.stdoutReader, session.stderrReader].compactMap { $0 }.count)

            tcpHandler.setStdinWriter(session.stdinWriter)
            tcpHandler.setCloseStdinOnInactive(false)

            DockerStreamRuntime.installUpgradedReadabilityHandler(
                on: session.stdoutReader,
                streamType: .stdout,
                tty: isTTY,
                channel: channel,
                writeState: writeState,
                closeState: closeState,
                onEOF: {
                }
            )

            DockerStreamRuntime.installUpgradedReadabilityHandler(
                on: session.stderrReader,
                streamType: .stderr,
                tty: isTTY,
                channel: channel,
                writeState: writeState,
                closeState: closeState,
                onEOF: {
                }
            )

            await withTaskGroup(of: Void.self) { group in
                let autoStartBeganAt = shouldAutoStart ? Date() : nil
                let networkContext = shouldAutoStart ? await resolveEventNetworkContext(for: container, logger: req.logger) : nil

                group.addTask {
                    guard shouldAutoStart else {
                        return
                    }
                    do {
                        try await attachSessionManager.start(containerID: container.id)
                    } catch {
                        closeState.markProcessExited()
                        DockerStreamRuntime.requestCloseIfPossible(channel: channel, writeState: writeState, closeState: closeState)
                    }
                }

                group.addTask {
                    defer {
                        session.closeClientHandles()
                        Swift.Task {
                            await attachSessionManager.remove(containerID: container.id)
                        }
                    }

                    let exitCode = await session.waitForExit()
                    await attachSessionManager.markCompleted(containerID: container.id, exitCode: exitCode)
                    if let broadcaster = req.eventBroadcaster {
                        let eventLabels = SocktainerContainerMetadata.userVisibleLabels(from: container.configuration.labels)
                        let containerName = container.configuration.labels[SocktainerContainerMetadata.containerNameLabel] ?? container.id
                        var dieLabels = eventLabels
                        if let autoStartBeganAt {
                            dieLabels["execDuration"] = String(max(0, Int(Date().timeIntervalSince(autoStartBeganAt))))
                        }
                        if containerAutoRemove(container), let networkContext {
                            await broadcaster.broadcast(
                                networkLifecycleEvent(
                                    network: networkContext,
                                    action: "disconnect",
                                    containerID: container.id
                                )
                            )
                        }
                        let event = DockerEvent.simpleEvent(
                            id: container.id,
                            type: "container",
                            status: "die",
                            from: container.configuration.image.reference,
                            name: containerName,
                            image: container.configuration.image.reference,
                            exitCode: String(exitCode),
                            labels: dieLabels
                        )
                        await broadcaster.broadcast(event)
                        if containerAutoRemove(container) {
                            await broadcaster.broadcast(
                                DockerEvent.simpleEvent(
                                    id: container.id,
                                    type: "container",
                                    status: "destroy",
                                    from: container.configuration.image.reference,
                                    name: containerName,
                                    image: container.configuration.image.reference,
                                    labels: eventLabels
                                )
                            )
                        }
                    }
                    await DockerStreamRuntime.emitTrailingOutputToChannel(
                        stdout: session.stdoutReader,
                        stderr: session.stderrReader,
                        tty: isTTY,
                        channel: channel,
                        closeState: closeState
                    )
                    closeState.markProcessExited()
                    DockerStreamRuntime.requestCloseIfPossible(channel: channel, writeState: writeState, closeState: closeState)
                }

                for await _ in group {}
            }
        }
    }

}
