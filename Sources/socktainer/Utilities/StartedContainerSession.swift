import ContainerAPIClient
import Vapor

actor StartedContainerSessionManager {
    private var sessions: [String: ClientProcessIOSession] = [:]
    private var completions: [String: Int64] = [:]

    func prepare(containerID: String, runtime: String, process: ClientProcess) -> ClientProcessIOSession {
        if let existing = sessions[containerID] {
            return existing
        }

        completions.removeValue(forKey: containerID)

        let session = ContainerSessionUtility.makeSession(
            containerID: containerID,
            runtime: runtime,
            process: process,
            stdinPipe: nil,
            stdoutPipe: nil,
            stderrPipe: nil
        )
        sessions[containerID] = session
        return session
    }

    func waitForExit(containerID: String) async -> Int64? {
        if let completion = completions[containerID] {
            return completion
        }
        guard let session = sessions[containerID] else {
            return nil
        }

        let exitCode = await session.waitForExit()
        guard exitCode >= 0 else {
            return nil
        }
        completions[containerID] = exitCode
        return exitCode
    }

    func exitCodeIfAvailable(containerID: String) -> Int64? {
        ContainerSessionUtility.exitCodeIfAvailable(
            session: sessions[containerID],
            completion: completions[containerID]
        )
    }

    func hasStarted(containerID: String) -> Bool {
        ContainerSessionUtility.hasStarted(session: sessions[containerID])
    }

    func remove(containerID: String) {
        sessions.removeValue(forKey: containerID)
        completions.removeValue(forKey: containerID)
    }
}

struct StartedContainerSessionManagerKey: StorageKey {
    typealias Value = StartedContainerSessionManager
}
