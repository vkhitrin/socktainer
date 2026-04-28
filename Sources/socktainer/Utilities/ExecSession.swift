import ContainerAPIClient
import Vapor

actor ExecSessionManager {
    private static func generatedExecID() -> String {
        let first = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let second = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return first + second
    }

    struct ExecConfig: Sendable {
        let containerId: String
        let cmd: [String]
        let attachStdin: Bool
        let attachStdout: Bool
        let attachStderr: Bool
        let tty: Bool
        let detachKeys: String
        let consoleSize: [Int]?
        let environment: [String]
        let user: String
        let workingDir: String
        let privileged: Bool
    }

    struct ExecRecord: Sendable {
        let containerId: String
        let cmd: [String]
        let attachStdin: Bool
        let attachStdout: Bool
        let attachStderr: Bool
        let tty: Bool
        let detachKeys: String
        var consoleSize: [Int]?
        let environment: [String]
        let user: String
        let workingDir: String
        let privileged: Bool
        // NOTE: This is the logical Apple container process identifier that
        // socktainer passes back into the client API for start/wait/kill calls.
        // It is not an OS PID and must not be exposed as Docker's exec `Pid`.
        var processId: String?
        var running: Bool
        var exitCode: Int?
        var session: ClientProcessIOSession?
        var process: (any ClientProcess)?
    }

    private var storage: [String: ExecRecord] = [:]

    private func record(for id: String) throws -> ExecRecord {
        guard let record = storage[id] else {
            throw Abort(.notFound, reason: "No such exec instance: \(id)")
        }
        return record
    }

    private func validateNotStarted(_ record: ExecRecord) throws {
        guard record.processId == nil, record.session == nil, record.exitCode == nil else {
            throw Abort(.conflict, reason: "Exec command has already run")
        }
    }

    private func markStarted(
        _ record: inout ExecRecord,
        processId: String,
        process: any ClientProcess,
        session: ClientProcessIOSession?
    ) {
        record.processId = processId
        record.running = true
        record.exitCode = nil
        record.session = session
        record.process = process
    }

    private func clearRuntimeState(_ record: inout ExecRecord, exitCode: Int?) {
        if let exitCode {
            record.exitCode = exitCode
        } else {
            record.exitCode = nil
        }
        record.processId = nil
        record.running = false
        record.session = nil
        record.process = nil
    }

    func create(config: ExecConfig) -> String {
        let id = Self.generatedExecID()
        storage[id] = ExecRecord(
            containerId: config.containerId,
            cmd: config.cmd,
            attachStdin: config.attachStdin,
            attachStdout: config.attachStdout,
            attachStderr: config.attachStderr,
            tty: config.tty,
            detachKeys: config.detachKeys,
            consoleSize: config.consoleSize,
            environment: config.environment,
            user: config.user,
            workingDir: config.workingDir,
            privileged: config.privileged,
            processId: nil,
            running: false,
            exitCode: nil,
            session: nil,
            process: nil
        )
        return id
    }

    func get(id: String) -> ExecRecord? {
        storage[id]
    }

    func runningExecIDs(containerId: String) -> [String] {
        storage.compactMap { execId, record in
            guard record.containerId == containerId, record.running else {
                return nil
            }
            return execId
        }.sorted()
    }

    func updateConsoleSize(id: String, consoleSize: [Int]?) throws {
        var record = try record(for: id)
        record.consoleSize = consoleSize
        storage[id] = record
    }

    func resizeSession(id: String, consoleSize: [Int]) async throws {
        let record = try record(for: id)
        guard record.tty else {
            throw Abort(.badRequest, reason: "Exec instance was not created with Tty enabled")
        }
        guard record.running else {
            throw Abort(.badRequest, reason: "Exec instance is not running")
        }
        let process = record.session?.process ?? record.process
        guard let process else {
            throw Abort(.badRequest, reason: "Exec instance cannot be resized")
        }

        try await process.resize(
            .init(width: UInt16(consoleSize[1]), height: UInt16(consoleSize[0]))
        )

        var updatedRecord = record
        updatedRecord.consoleSize = consoleSize
        storage[id] = updatedRecord
    }

    func prepareSession(
        id: String,
        processId: String,
        process: ClientProcess,
        stdinPipe: Pipe?,
        stdoutPipe: Pipe?,
        stderrPipe: Pipe?
    ) throws -> ClientProcessIOSession {
        var record = try record(for: id)
        try validateNotStarted(record)

        let session = ClientProcessIOSession(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            waitFailureExitCode: -1
        )
        markStarted(&record, processId: processId, process: process, session: session)
        storage[id] = record
        return session
    }

    func markDetachedStarted(id: String, processId: String, process: any ClientProcess) throws {
        var record = try record(for: id)
        try validateNotStarted(record)
        markStarted(&record, processId: processId, process: process, session: nil)
        storage[id] = record
    }

    func markExited(id: String, exitCode: Int) {
        guard var record = storage[id] else {
            return
        }
        clearRuntimeState(&record, exitCode: exitCode)
        storage[id] = record
    }

    func resetFailedStart(id: String) {
        guard var record = storage[id] else {
            return
        }
        clearRuntimeState(&record, exitCode: nil)
        storage[id] = record
    }
}

struct ExecSessionManagerKey: StorageKey {
    typealias Value = ExecSessionManager
}
