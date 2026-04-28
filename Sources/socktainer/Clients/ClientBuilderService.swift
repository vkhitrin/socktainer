import ContainerAPIClient
import ContainerBuild
import ContainerCommands
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import NIO
import Vapor

struct BuilderPruneRequest: Sendable {
    let all: Bool
    let filters: [String: [String]]
    let keepStorage: Int64?
    let reservedSpace: Int64?
    let maxUsedSpace: Int64?
    let minFreeSpace: Int64?
}

struct BuilderPruneResult: Sendable {
    let deletedCaches: [String]
    let spaceReclaimed: Int64
}

struct BuilderCacheRecord: Sendable {
    let id: String
    let parents: [String]
    let kind: String?
    let description: String?
    let inUse: Bool
    let shared: Bool
    let size: Int64
    let createdAt: String?
    let lastUsedAt: String?
    let usageCount: Int
}

protocol ClientBuilderProtocol: Sendable {
    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws
    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws -> Builder
    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult
    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord]
}

struct ClientBuilderService: ClientBuilderProtocol {
    private let containerClient = ContainerClient()
    private let networkClient = NetworkClient()
    private let builderContainerId: String
    private let builderPort: UInt32

    init(
        builderContainerId: String = "buildkit",
        builderPort: UInt32 = 8088
    ) {
        self.builderContainerId = builderContainerId
        self.builderPort = builderPort
    }

    func prune(_ request: BuilderPruneRequest, logger: Logger) async throws -> BuilderPruneResult {
        let command = try BuildctlUtility.pruneCommand(from: request)
        let stdoutText = try await executeWithBuilderRecovery(
            command: command,
            actionName: "buildctl prune",
            logger: logger
        )

        let entries = BuildctlUtility.parsePruneOutput(stdoutText, logger: logger)
        let deletedIds = entries.compactMap(\.id)
        let reclaimed = entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        return BuilderPruneResult(deletedCaches: deletedIds, spaceReclaimed: reclaimed)
    }

    func diskUsage(logger: Logger) async throws -> [BuilderCacheRecord] {
        let command = BuildctlUtility.duCommand()
        let stdoutText = try await executeWithBuilderRecovery(
            command: command,
            actionName: "buildctl du",
            logger: logger
        )

        return try BuildctlUtility.parseDuOutput(stdoutText, logger: logger).compactMap { record in
            guard let id = record.id else {
                return nil
            }
            return BuilderCacheRecord(
                id: id,
                parents: record.parents ?? [],
                kind: record.recordType,
                description: record.recordDescription,
                inUse: record.inUse ?? false,
                shared: record.shared ?? false,
                size: record.size ?? 0,
                createdAt: record.createdAt,
                lastUsedAt: record.lastUsedAt,
                usageCount: record.usageCount ?? 0
            )
        }
    }

    func ensureReachable(timeout: Duration, retryInterval: Duration, logger: Logger) async throws {
        try await ensureNativeBuilderStarted(logger: logger)
        _ = try await runningBuilderContainer(logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket()
                try? socket.close()
                return
            } catch {
                lastError = error
                logger.debug("Builder reachability check failed: \(error)")
            }

            try await Swift.Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for builder reachability")
    }

    func connect(timeout: Duration, retryInterval: Duration, logger: Logger) async throws -> Builder {
        try await ensureNativeBuilderStarted(logger: logger)
        _ = try await runningBuilderContainer(logger: logger)

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastError: Error?

        while clock.now < deadline {
            do {
                let socket = try await dialBuilderSocket()
                let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                let builder = try Builder(socket: socket, group: group, logger: logger)
                do {
                    _ = try await builder.info()
                    return builder
                } catch {
                    try? await group.shutdownGracefully()
                    throw error
                }
            } catch {
                lastError = error
                logger.debug("Builder connection attempt failed: \(error)")
            }

            try await Swift.Task.sleep(for: retryInterval)
        }

        if let lastError {
            throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder: \(lastError)")
        }
        throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder")
    }

    private func dialBuilderSocket() async throws -> FileHandle {
        let container = try await runningBuilderContainer(logger: nil)
        return try await containerClient.dial(id: container.id, port: builderPort)
    }

    private func runningBuilderContainer(logger: Logger?) async throws -> ContainerSnapshot {
        let container = try await containerClient.get(id: builderContainerId)

        guard container.status == .running else {
            switch container.status {
            case .running:
                return container
            case .stopped:
                logger?.info("Builder container is stopped, starting it via native Apple builder path")
                try await ensureNativeBuilderStarted(logger: logger)
                return try await containerClient.get(id: builderContainerId)
            case .stopping:
                throw ContainerizationError(.invalidState, message: "BuildKit container '\(builderContainerId)' is stopping")
            case .unknown:
                logger?.warning("Builder container has unknown state, recreating it via native Apple builder path")
                try await ensureNativeBuilderStarted(logger: logger)
                return try await containerClient.get(id: builderContainerId)
            @unknown default:
                throw ContainerizationError(.invalidState, message: "BuildKit container '\(builderContainerId)' is in an unsupported state")
            }
        }

        return container
    }

    private func ensureNativeBuilderStarted(logger: Logger?) async throws {
        _ = logger
        let command = try ContainerCommands.Application.BuilderStart.parse([])
        try await command.run()
    }

    private func startBuildKit(containerId: String) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }

        do {
            let process = try await containerClient.bootstrap(id: containerId, stdio: io.stdio)
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? await containerClient.stop(id: containerId)
            try? await containerClient.delete(id: containerId)
            if let containerizationError = error as? ContainerizationError {
                throw containerizationError
            }
            throw ContainerizationError(.internalError, message: "failed to start BuildKit: \(error)")
        }
    }

    private func execute(command: BuildctlUtility.Command, in container: ContainerSnapshot, actionName: String, logger: Logger) async throws -> String {
        var processConfig = container.configuration.initProcess
        processConfig.executable = command.executable
        processConfig.arguments = command.arguments
        processConfig.terminal = false

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try await containerClient.createProcess(
            containerId: container.id,
            processId: UUID().uuidString.lowercased(),
            configuration: processConfig,
            stdio: [nil, stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting]
        )

        let session = ClientProcessIOSession(
            process: process,
            stdinPipe: nil,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            waitFailureExitCode: -1
        )
        defer { session.closeClientHandles() }

        try await session.start()
        let exitCode = await session.waitForExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if !stderrText.isEmpty {
            logger.error("\(actionName) stderr:\n\(stderrText)")
        }

        guard exitCode == 0 else {
            let details = stderrText.isEmpty ? stdoutText : stderrText
            throw ContainerizationError(.unknown, message: "\(actionName) failed with exit code \(exitCode): \(details)")
        }

        return stdoutText
    }

    private func executeWithBuilderRecovery(
        command: BuildctlUtility.Command,
        actionName: String,
        logger: Logger
    ) async throws -> String {
        do {
            let container = try await runningBuilderContainer(logger: logger)
            return try await execute(command: command, in: container, actionName: actionName, logger: logger)
        } catch {
            guard shouldRecreateBuilder(after: error) else {
                throw error
            }

            logger.warning("\(actionName) failed due to missing BuildKit socket; recreating builder and retrying once")
            try? await containerClient.stop(id: builderContainerId)
            try? await containerClient.delete(id: builderContainerId)

            try await ensureNativeBuilderStarted(logger: logger)
            let container = try await runningBuilderContainer(logger: logger)
            return try await execute(command: command, in: container, actionName: actionName, logger: logger)
        }
    }

    private func shouldRecreateBuilder(after error: any Error) -> Bool {
        let message = String(describing: error)
        return message.contains("/run/buildkit/buildkitd.sock")
            || message.contains("buildctl")
                && message.contains("connect: no such file or directory")
    }

}
