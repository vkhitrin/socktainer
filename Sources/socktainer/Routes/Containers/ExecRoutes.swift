import ContainerAPIClient
import ContainerResource
import ContainerizationOS
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor

private struct ExecStdio {
    let stdin: FileHandle?
    let stdout: FileHandle?
    let stderr: FileHandle?

    var asArray: [FileHandle?] {
        [stdin, stdout, stderr]
    }
}

struct ExecRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/exec", use: ExecRoute.createExec(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/exec/{id}/json", use: ExecRoute.inspectExec())
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id}/start", use: ExecRoute.startExec(client: client))
        try routes.registerVersionedRoute(.POST, pattern: "/exec/{id}/resize", use: ExecRoute.resizeExec())
    }
}

extension ExecRoute {
    private static func jsonResponse(_ object: Any) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    private static func validateConsoleSize(_ consoleSize: [Int]?) throws -> [Int]? {
        guard let consoleSize else {
            return nil
        }
        guard consoleSize.count == 2 else {
            throw Abort(.badRequest, reason: "ConsoleSize must contain exactly two integers")
        }
        guard consoleSize.allSatisfy({ $0 >= 0 }) else {
            throw Abort(.badRequest, reason: "ConsoleSize values must be non-negative")
        }
        guard consoleSize.allSatisfy({ $0 <= Int(UInt16.max) }) else {
            throw Abort(.badRequest, reason: "ConsoleSize values must be <= \(UInt16.max)")
        }
        return consoleSize
    }

    private static func terminalSize(from consoleSize: [Int]) -> ContainerizationOS.Terminal.Size {
        .init(
            width: UInt16(consoleSize[1]),
            height: UInt16(consoleSize[0])
        )
    }

    private static func applyConsoleSize(_ consoleSize: [Int]?, tty: Bool, process: ClientProcess) async throws {
        guard let consoleSize else {
            return
        }
        guard tty else {
            throw Abort(.badRequest, reason: "ConsoleSize requires Tty to be enabled")
        }
        try await process.resize(terminalSize(from: consoleSize))
    }

    private static func validateResizeConsoleSize(height: Int, width: Int) throws -> [Int] {
        try validateConsoleSize([height, width]) ?? [height, width]
    }

    private static func processUserString(_ user: ProcessConfiguration.User) -> String {
        switch user {
        case .raw(let userString):
            return userString
        case .id(let uid, let gid):
            return "\(uid):\(gid)"
        }
    }

    private static func execSessionManager(req: Request) throws -> ExecSessionManager {
        guard let manager = req.application.storage[ExecSessionManagerKey.self] else {
            throw Abort(.internalServerError, reason: "Exec session manager not configured")
        }
        return manager
    }

    private static func execCommand(from config: ExecSessionManager.ExecRecord) throws -> (executable: String, arguments: [String]) {
        guard let executable = config.cmd.first, !executable.isEmpty else {
            throw Abort(.badRequest, reason: "Exec command is empty")
        }
        return (executable, Array(config.cmd.dropFirst()))
    }

    private static func startAttachedExecSession(
        session: ClientProcessIOSession,
        consoleSize: [Int]?,
        tty: Bool,
        process: ClientProcess,
        manager: ExecSessionManager,
        execId: String,
        request: Request,
        container: ContainerSnapshot
    ) async throws {
        do {
            try await session.start()
            try await applyConsoleSize(consoleSize, tty: tty, process: process)
            await ContainerEventUtility.broadcastContainerEvent(
                request: request,
                status: "exec_start",
                container: container,
                containerID: container.id
            )
        } catch {
            session.closeClientHandles()
            await manager.resetFailedStart(id: execId)
            throw error
        }
    }

    private static func finishAttachedExecSession(
        session: ClientProcessIOSession,
        tty: Bool,
        manager: ExecSessionManager,
        execId: String,
        request: Request,
        container: ContainerSnapshot,
        afterWait: @Sendable (ClientProcessIOSession, Int64) async -> Void
    ) async {
        let exitCode = await session.waitForExit()
        await afterWait(session, exitCode)
        await manager.markExited(id: execId, exitCode: Int(exitCode))
        await ContainerEventUtility.broadcastContainerEvent(
            request: request,
            status: "exec_die",
            container: container,
            containerID: container.id,
            exitCode: String(exitCode)
        )
    }

    private static func requiredExecID(from request: Request) throws -> String {
        guard let execId = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing exec ID")
        }
        return execId
    }

    private static func execConfigContext(
        request: Request
    ) async throws -> (execId: String, manager: ExecSessionManager, config: ExecSessionManager.ExecRecord) {
        let execId = try requiredExecID(from: request)
        let manager = try execSessionManager(req: request)
        guard let config = await manager.get(id: execId) else {
            throw Abort(.notFound, reason: "No such exec instance: \(execId)")
        }
        return (execId, manager, config)
    }

    static func inspectExec() -> @Sendable (Request) async throws -> Response {
        { req in
            let (execId, _, config) = try await execConfigContext(request: req)

            let response = ExecInspectResponse(
                canRemove: !config.running,
                detachKeys: config.detachKeys,
                ID: execId,
                running: config.running,
                exitCode: config.exitCode,
                processConfig: ProcessConfig(
                    privileged: config.privileged,
                    user: config.user,
                    tty: config.tty,
                    entrypoint: config.cmd.first ?? "",
                    arguments: Array(config.cmd.dropFirst())
                ),
                openStdin: config.attachStdin,
                openStderr: config.attachStderr,
                openStdout: config.attachStdout,
                containerID: config.containerId,
                // NOTE: Apple container's exec/session API surface used here does
                // not expose a Docker-compatible exec PID for later inspection.
                // Return Docker's zero/default-compatible value instead of
                // omitting the key entirely.
                pid: 0
            )
            let encoded = try JSONEncoder().encode(response)
            guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                throw Abort(.internalServerError, reason: "Failed to encode exec inspect response")
            }
            payload["CanRemove"] = false
            if payload["ExitCode"] == nil {
                payload["ExitCode"] = NSNull()
            }
            if payload["Pid"] == nil {
                payload["Pid"] = 0
            }
            return try jsonResponse(payload)
        }
    }

    static func createExec(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: containerId) else {
                throw ContainerEventUtility.notFoundAbort(containerID: containerId)
            }

            do {
                try client.enforceContainerRunning(container: container)
            } catch {
                throw Abort(.conflict, reason: "Container is not running")
            }

            let body = try req.content.decode(ExecConfig.self)
            let consoleSize = try validateConsoleSize(body.consoleSize)
            guard let executable = body.cmd?.first, !executable.isEmpty else {
                throw Abort(.badRequest, reason: "Exec command is empty")
            }
            _ = executable

            var attachStderr = body.attachStderr ?? true
            if body.tty ?? false {
                attachStderr = false
            }

            let manager = try execSessionManager(req: req)
            let id = await manager.create(
                config: .init(
                    containerId: container.id,
                    cmd: body.cmd ?? [],
                    attachStdin: body.attachStdin ?? false,
                    attachStdout: body.attachStdout ?? true,
                    attachStderr: attachStderr,
                    tty: body.tty ?? false,
                    detachKeys: body.detachKeys ?? "",
                    consoleSize: consoleSize,
                    environment: body.env ?? [],
                    // Docker's exec inspect reports the requested exec user,
                    // not the container's effective default user. Keep the
                    // request value here and apply the container fallback only
                    // when starting the process for Apple.
                    user: body.user ?? "",
                    workingDir: body.workingDir ?? container.configuration.initProcess.workingDirectory,
                    privileged: body.privileged ?? false
                )
            )

            await ContainerEventUtility.broadcastContainerEvent(
                request: req,
                status: "exec_create",
                container: container,
                containerID: container.id
            )

            return try await IDResponse(id: id).encodeResponse(status: .created, for: req)
        }
    }

    static func resizeExec() -> @Sendable (Request) async throws -> Response {
        { req in
            let execId = try requiredExecID(from: req)
            let resizeRequest = try req.query.decode(ExecResizeQuery.self)
            let consoleSize = try validateResizeConsoleSize(height: resizeRequest.h, width: resizeRequest.w)
            let manager = try execSessionManager(req: req)
            try await manager.resizeSession(id: execId, consoleSize: consoleSize)
            return Response(status: .ok)
        }
    }

    static func startExec(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let (execId, manager, config) = try await execConfigContext(request: req)

            if config.processId != nil || config.exitCode != nil || config.running {
                throw Abort(.conflict, reason: "Exec command has already run")
            }

            guard let container = try await client.getContainer(id: config.containerId) else {
                throw ContainerEventUtility.notFoundAbort(containerID: config.containerId)
            }

            do {
                try client.enforceContainerRunning(container: container)
            } catch ClientContainerError.notRunning {
                throw Abort(.conflict, reason: "Container is not running")
            }

            let startRequest = try req.content.decode(ExecStartConfig.self)
            let detach = startRequest.detach ?? false
            let tty = startRequest.tty ?? config.tty
            let startConsoleSize = try validateConsoleSize(startRequest.consoleSize)
            let effectiveConsoleSize = startConsoleSize ?? config.consoleSize
            if let startConsoleSize {
                try await manager.updateConsoleSize(id: execId, consoleSize: startConsoleSize)
            }

            let (executable, arguments) = try execCommand(from: config)
            var processConfig = container.configuration.initProcess
            processConfig.executable = executable
            processConfig.arguments = arguments
            processConfig.terminal = tty
            if !config.environment.isEmpty {
                processConfig.environment = config.environment
            }
            if !config.workingDir.isEmpty {
                processConfig.workingDirectory = config.workingDir
            }
            if !config.user.isEmpty {
                processConfig.user = .raw(userString: config.user)
            } else {
                processConfig.user = container.configuration.initProcess.user
            }
            // NOTE: Apple container requires a logical process identifier when
            // creating exec processes. This is an opaque process handle, not an
            // OS PID, so inspect must continue to report `Pid: nil`.
            let processId = UUID().uuidString.lowercased()
            if detach {
                let process = try await ContainerClient().createProcess(
                    containerId: container.id,
                    processId: processId,
                    configuration: processConfig,
                    stdio: [nil, nil, nil]
                )
                try await process.start()
                try await applyConsoleSize(effectiveConsoleSize, tty: tty, process: process)
                try await manager.markDetachedStarted(id: execId, processId: processId, process: process)
                await ContainerEventUtility.broadcastContainerEvent(
                    request: req,
                    status: "exec_start",
                    container: container,
                    containerID: container.id
                )
                Swift.Task {
                    let exitCode = (try? await process.wait()) ?? -1
                    await manager.markExited(id: execId, exitCode: Int(exitCode))
                    await ContainerEventUtility.broadcastContainerEvent(
                        request: req,
                        status: "exec_die",
                        container: container,
                        containerID: container.id,
                        exitCode: String(exitCode)
                    )
                }
                return Response(status: .ok)
            }

            let stdinPipe: Pipe? = config.attachStdin ? Pipe() : nil
            let stdoutPipe: Pipe? = config.attachStdout ? Pipe() : nil
            let stderrPipe: Pipe? = (config.attachStderr && !tty) ? Pipe() : nil
            let stdio = ExecStdio(
                stdin: stdinPipe?.fileHandleForReading,
                stdout: stdoutPipe?.fileHandleForWriting,
                stderr: stderrPipe?.fileHandleForWriting
            )

            let process = try await ContainerClient().createProcess(
                containerId: container.id,
                processId: processId,
                configuration: processConfig,
                stdio: stdio.asArray
            )

            let session = try await manager.prepareSession(
                id: execId,
                processId: processId,
                process: process,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )

            let connectionHeader = req.headers.first(name: "Connection")?.lowercased()
            let upgradeHeader = req.headers.first(name: "Upgrade")?.lowercased()
            let shouldUpgrade = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp"
            guard shouldUpgrade else {
                return DockerPlainStreamingResponse.create(
                    request: req,
                    ttyEnabled: tty,
                    nonTTYContentType: "application/vnd.docker.raw-stream"
                ) { streamContinuation in
                    DockerStreamRuntime.installReadabilityHandler(
                        on: session.stdoutReader,
                        streamType: .stdout,
                        tty: tty,
                        allocator: sharedAllocator,
                        onChunk: { streamContinuation.yield($0) },
                        onEOF: {}
                    )

                    DockerStreamRuntime.installReadabilityHandler(
                        on: session.stderrReader,
                        streamType: .stderr,
                        tty: tty,
                        allocator: sharedAllocator,
                        onChunk: { streamContinuation.yield($0) },
                        onEOF: {}
                    )

                    do {
                        try await startAttachedExecSession(
                            session: session,
                            consoleSize: effectiveConsoleSize,
                            tty: tty,
                            process: process,
                            manager: manager,
                            execId: execId,
                            request: req,
                            container: container
                        )
                    } catch {
                        streamContinuation.finish(throwing: error)
                        return
                    }

                    await withTaskGroup(of: Void.self) { group in
                        if let stdinWriter = session.stdinWriter {
                            group.addTask {
                                await DockerStreamRuntime.forwardBody(req.body, to: stdinWriter)
                            }
                        }

                        group.addTask {
                            defer {
                                session.closeClientHandles()
                                streamContinuation.finish()
                            }

                            await finishAttachedExecSession(
                                session: session,
                                tty: tty,
                                manager: manager,
                                execId: execId,
                                request: req,
                                container: container
                            ) { session, _ in
                                DockerStreamRuntime.emitTrailingOutput(
                                    stdout: session.stdoutReader,
                                    stderr: session.stderrReader,
                                    tty: tty,
                                    emit: { streamContinuation.yield($0) }
                                )
                            }
                        }

                        for await _ in group {}
                    }
                }
            }

            return Response.dockerRawStreamUpgrade(
                ttyEnabled: tty
            ) { channel, tcpHandler in
                let writeState = DockerUpgradeWriteState()
                let outputState = DockerUpgradeCloseState(
                    configuredStreams: [session.stdoutReader, session.stderrReader].compactMap { $0 }.count
                )
                tcpHandler.setCloseStdinOnInactive(false)

                DockerStreamRuntime.installUpgradedReadabilityHandler(
                    on: session.stdoutReader,
                    streamType: .stdout,
                    tty: tty,
                    channel: channel,
                    writeState: writeState,
                    closeState: outputState,
                    onEOF: {
                    }
                )

                DockerStreamRuntime.installUpgradedReadabilityHandler(
                    on: session.stderrReader,
                    streamType: .stderr,
                    tty: tty,
                    channel: channel,
                    writeState: writeState,
                    closeState: outputState,
                    onEOF: {
                    }
                )

                do {
                    try await startAttachedExecSession(
                        session: session,
                        consoleSize: effectiveConsoleSize,
                        tty: tty,
                        process: process,
                        manager: manager,
                        execId: execId,
                        request: req,
                        container: container
                    )
                    if config.attachStdin {
                        tcpHandler.setStdinWriter(session.stdinWriter)
                        if tcpHandler.inputClosedObserved(), let processStdin = session.stdinWriter {
                            Swift.Task.detached {
                                try? await Swift.Task.sleep(nanoseconds: 100_000_000)
                                try? processStdin.close()
                            }
                        }
                    }
                } catch {
                    session.closeClientHandles()
                    await manager.resetFailedStart(id: execId)
                    throw error
                }

                defer {
                    tcpHandler.setStdinWriter(nil)
                    session.closeClientHandles()
                }

                await finishAttachedExecSession(
                    session: session,
                    tty: tty,
                    manager: manager,
                    execId: execId,
                    request: req,
                    container: container
                ) { session, _ in
                    await DockerStreamRuntime.emitTrailingOutputToChannel(
                        stdout: session.stdoutReader,
                        stderr: session.stderrReader,
                        tty: tty,
                        channel: channel,
                        closeState: outputState
                    )
                    outputState.markProcessExited()
                }
                DockerStreamRuntime.requestCloseIfPossible(channel: channel, writeState: writeState, closeState: outputState)
            }
        }
    }
}
