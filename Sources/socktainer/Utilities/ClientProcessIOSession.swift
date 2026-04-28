import ContainerAPIClient
import ContainerSandboxServiceClient
import Foundation
import NIOConcurrencyHelpers

// Safe as @unchecked Sendable because cross-task mutable state is contained in
// NIOLockedValueBox and process/pipe handles are only exposed through
// synchronized session lifecycle methods.
final class ClientProcessIOSession: @unchecked Sendable {
    private struct State {
        var started = false
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var exitTask: Swift.Task<Int64, Never>?
        var completedExitCode: Int64?
        var bootstrapHandlesClosed = false
        var clientHandlesClosed = false
    }

    let process: ClientProcess
    let stdinPipe: Pipe?
    let stdoutPipe: Pipe?
    let stderrPipe: Pipe?

    private let waitFailureExitCode: Int64
    private let waitFallback: (@Sendable () async -> Int64?)?
    private let state = NIOLockedValueBox(State())

    init(
        process: ClientProcess,
        stdinPipe: Pipe?,
        stdoutPipe: Pipe?,
        stderrPipe: Pipe?,
        waitFailureExitCode: Int64,
        waitFallback: (@Sendable () async -> Int64?)? = nil
    ) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.waitFailureExitCode = waitFailureExitCode
        self.waitFallback = waitFallback
    }

    var stdinWriter: FileHandle? {
        stdinPipe?.fileHandleForWriting
    }

    var stdoutReader: FileHandle? {
        stdoutPipe?.fileHandleForReading
    }

    var stderrReader: FileHandle? {
        stderrPipe?.fileHandleForReading
    }

    func start() async throws {
        let shouldStart = state.withLockedValue { state in
            guard !state.started else {
                return false
            }
            state.started = true
            return true
        }

        guard shouldStart else {
            return
        }

        try await process.start()
        closeBootstrapHandles()

        let exitTask = Swift.Task<Int64, Never> { [process, waitFailureExitCode, waitFallback, state] in
            let exitCode: Int64
            do {
                exitCode = Int64(try await process.wait())
            } catch {
                if let recoveredExitCode = await waitFallback?() {
                    exitCode = recoveredExitCode
                } else {
                    exitCode = waitFailureExitCode
                }
            }
            state.withLockedValue { state in
                state.completedExitCode = exitCode
            }
            return exitCode
        }

        let waiters = state.withLockedValue { state in
            state.exitTask = exitTask
            let waiters = state.startWaiters
            state.startWaiters.removeAll()
            return waiters
        }

        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForExit() async -> Int64 {
        let exitTask = state.withLockedValue { state in
            state.exitTask
        }

        if let exitTask {
            return await exitTask.value
        }

        await withCheckedContinuation { continuation in
            state.withLockedValue { state in
                if state.exitTask != nil {
                    continuation.resume()
                } else {
                    state.startWaiters.append(continuation)
                }
            }
        }

        let startedExitTask = state.withLockedValue { state in
            state.exitTask
        }

        guard let startedExitTask else {
            return waitFailureExitCode
        }

        return await startedExitTask.value
    }

    func exitCodeIfAvailable() -> Int64? {
        state.withLockedValue { state in
            state.completedExitCode
        }
    }

    var hasStarted: Bool {
        state.withLockedValue { state in
            state.started
        }
    }

    func closeBootstrapHandles() {
        let shouldClose = state.withLockedValue { state in
            guard !state.bootstrapHandlesClosed else {
                return false
            }
            state.bootstrapHandlesClosed = true
            return true
        }

        guard shouldClose else {
            return
        }

        stdinPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe?.fileHandleForWriting.readabilityHandler = nil
        stderrPipe?.fileHandleForWriting.readabilityHandler = nil
        try? stdinPipe?.fileHandleForReading.close()
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
    }

    func closeClientHandles() {
        let shouldClose = state.withLockedValue { state in
            guard !state.clientHandlesClosed else {
                return false
            }
            state.clientHandlesClosed = true
            return true
        }

        guard shouldClose else {
            return
        }

        stdinPipe?.fileHandleForWriting.readabilityHandler = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
    }
}
