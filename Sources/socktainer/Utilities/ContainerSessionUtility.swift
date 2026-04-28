import ContainerAPIClient
import ContainerSandboxServiceClient
import Vapor

enum ContainerSessionUtility {
    static func makeSession(
        containerID: String,
        runtime: String,
        process: ClientProcess,
        stdinPipe: Pipe?,
        stdoutPipe: Pipe?,
        stderrPipe: Pipe?
    ) -> ClientProcessIOSession {
        ClientProcessIOSession(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            waitFailureExitCode: -1,
            waitFallback: {
                do {
                    let sandbox = try await SandboxClient.create(id: containerID, runtime: runtime)
                    let status = try await sandbox.wait(containerID)
                    return Int64(status.exitCode)
                } catch {
                    return nil
                }
            }
        )
    }

    static func exitCodeIfAvailable(
        session: ClientProcessIOSession?,
        completion: Int64? = nil
    ) -> Int64? {
        if let completion {
            return completion
        }
        guard let session else {
            return nil
        }
        guard let exitCode = session.exitCodeIfAvailable(), exitCode >= 0 else {
            return nil
        }
        return exitCode
    }

    static func hasStarted(session: ClientProcessIOSession?) -> Bool {
        session?.hasStarted == true
    }
}
