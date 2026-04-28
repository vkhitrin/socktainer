import ContainerAPIClient
import Vapor

struct StoppedContainerCompletion: Sendable {
    let exitCode: Int64
    let finishedAt: Date
}

actor StoppedContainerAttachSessionManager {
    private var sessions: [String: ClientProcessIOSession] = [:]
    private var completions: [String: StoppedContainerCompletion] = [:]

    func session(containerID: String) -> ClientProcessIOSession? {
        sessions[containerID]
    }

    func prepare(
        containerID: String,
        runtime: String,
        process: ClientProcess,
        stdinPipe: Pipe?,
        stdoutPipe: Pipe?,
        stderrPipe: Pipe?
    ) -> ClientProcessIOSession {
        if let existing = sessions[containerID] {
            return existing
        }

        completions.removeValue(forKey: containerID)

        let session = ContainerSessionUtility.makeSession(
            containerID: containerID,
            runtime: runtime,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        sessions[containerID] = session
        return session
    }

    @discardableResult
    func start(containerID: String) async throws -> Bool {
        guard let session = sessions[containerID] else {
            return false
        }
        try await session.start()
        return true
    }

    func waitForExit(containerID: String) async -> Int64? {
        guard let session = sessions[containerID] else {
            return completions[containerID]?.exitCode
        }
        let exitCode = await session.waitForExit()
        return exitCode >= 0 ? exitCode : nil
    }

    func exitCodeIfAvailable(containerID: String) -> Int64? {
        ContainerSessionUtility.exitCodeIfAvailable(
            session: sessions[containerID],
            completion: completions[containerID]?.exitCode
        )
    }

    func hasStarted(containerID: String) -> Bool {
        ContainerSessionUtility.hasStarted(session: sessions[containerID])
    }

    func markCompleted(containerID: String, exitCode: Int64, finishedAt: Date = Date()) {
        guard exitCode >= 0 else {
            return
        }
        completions[containerID] = StoppedContainerCompletion(exitCode: exitCode, finishedAt: finishedAt)
    }

    func completion(containerID: String) -> StoppedContainerCompletion? {
        completions[containerID]
    }

    func completions(containerIDs: [String]) -> [String: StoppedContainerCompletion] {
        Dictionary(
            uniqueKeysWithValues: containerIDs.compactMap { id in
                completions[id].map { (id, $0) }
            })
    }

    func remove(containerID: String) {
        sessions.removeValue(forKey: containerID)
    }
}

struct StoppedContainerAttachSessionManagerKey: StorageKey {
    typealias Value = StoppedContainerAttachSessionManager
}
