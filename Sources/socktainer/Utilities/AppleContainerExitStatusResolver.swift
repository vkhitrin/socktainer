import ContainerResource
import ContainerSandboxServiceClient
import Vapor

enum AppleContainerExitStatusResolver {
    private static let resolutionTimeout: Duration = .seconds(1)

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Swift.Task.sleep(for: timeout)
                throw CancellationError()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func resolveCompletion(for container: ContainerSnapshot) async -> StoppedContainerCompletion? {
        guard container.status == .stopped else {
            return nil
        }

        do {
            // NOTE: Apple does not expose a non-blocking "read last exit status"
            // API for stopped sandboxes. The only available path is `wait`, which
            // can hang indefinitely once the sandbox is already gone. Bound this
            // lookup so list/inspect routes fall back instead of hanging.
            let status = try await withTimeout(resolutionTimeout) {
                let sandbox = try await SandboxClient.create(
                    id: container.id,
                    runtime: container.configuration.runtimeHandler
                )
                return try await sandbox.wait(container.id)
            }
            guard status.exitCode >= 0 else {
                return nil
            }
            return StoppedContainerCompletion(
                exitCode: Int64(status.exitCode),
                finishedAt: status.exitedAt
            )
        } catch {
            return nil
        }
    }

    static func resolve(for container: ContainerSnapshot) async -> (code: Int, finishedAt: String)? {
        guard let completion = await resolveCompletion(for: container) else {
            return nil
        }

        return (
            Int(completion.exitCode),
            AppleContainerTimestampResolver.iso8601Timestamp(completion.finishedAt)
        )
    }
}
