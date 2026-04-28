import ContainerAPIClient
import Foundation
import NIOCore
import Vapor

struct ContainerLogsRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/logs", use: ContainerLogsRoute.handler(client: client))
    }
}

extension ContainerLogsRoute {
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

    private static func filteredLogPayload(from data: Data, query: ContainerLogsQuery) -> Data {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return data
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let tail = query.tail, tail != "all", let count = Int(tail), count >= 0, lines.count > count {
            lines = Array(lines.suffix(count))
        }

        let filtered = lines.joined(separator: "\n")
        return Data(filtered.utf8)
    }

    private static func writeLogChunk(
        _ data: Data,
        streamType: DockerStreamFrame.StreamType,
        ttyMode: Bool,
        query: ContainerLogsQuery,
        writer: BodyStreamWriter
    ) {
        let filtered = filteredLogPayload(from: data, query: query)
        guard !filtered.isEmpty else { return }

        var buffer = sharedAllocator.buffer(capacity: filtered.count + (ttyMode ? 0 : 8))
        buffer.writeDockerFrame(streamType: streamType, data: filtered, ttyMode: ttyMode)
        _ = writer.write(BodyStreamResult.buffer(buffer))
    }

    private static func isContainerRunning(
        id: String,
        client: ClientContainerProtocol
    ) async throws -> Bool {
        if let refreshed = try await client.getContainer(id: id) {
            return refreshed.status == .running
        }
        return false
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            let query = try req.query.decode(ContainerLogsQuery.self)
            if query.since != nil || query.until != nil {
                // NOTE: The Apple log API surface used here only exposes raw log
                // handles. It does not provide authoritative per-line timestamps,
                // so Docker's time-based log filtering cannot be implemented
                // truthfully from the available backend data.
                throw Abort(.badRequest, reason: "since/until log filtering is not supported")
            }
            if query.timestamps == true {
                // NOTE: For the same reason, socktainer cannot prepend Docker-style
                // timestamps without fabricating metadata that the backend does not
                // actually expose.
                throw Abort(.badRequest, reason: "timestamped log output is not supported")
            }
            if let tail = query.tail, tail != "all" {
                guard let count = Int(tail), count >= 0 else {
                    throw Abort(.badRequest, reason: "tail must be a non-negative integer or 'all'")
                }
                _ = count
            }
            let follow = query.follow ?? false
            let wantStdout = query.stdout ?? false
            let wantStderr = query.stderr ?? false
            let isTTY = container.configuration.initProcess.terminal
            let contentType = isTTY ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"

            let replayLogPath = stdioLogPath(for: container.id, req: req)

            let logHandles: [FileHandle]
            if replayLogPath == nil {
                logHandles = try await ContainerClient().logs(id: container.id)
            } else {
                logHandles = []
            }
            let stdoutHandle = logHandles.indices.contains(0) ? logHandles[0] : nil
            let stderrHandle = logHandles.indices.contains(1) ? logHandles[1] : nil

            // NOTE: Apple container exposes persisted raw log handles here rather
            // than Docker-style replay/filter primitives or structured log entries
            // with timestamps. That is why `tail` is applied locally, while
            // `since`/`until`/`timestamps` are rejected instead of being
            // approximated incorrectly.
            //
            // NOTE: Apple also persists process output only as a single combined
            // `stdio.log` file. socktainer prefers that file for both replay and
            // follow mode so it does not leak VM bootstrap stderr from the live
            // log handles.
            //
            // That means stdout/stderr separation is fundamentally unavailable
            // for this backend surface once output is replayed from `stdio.log`.
            // socktainer therefore emits the merged transcript on the stdout
            // channel when both were requested instead of fabricating split
            // Docker frames from data Apple does not actually preserve.
            let body = Response.Body { writer in
                Swift.Task.detached {
                    defer {
                        try? stdoutHandle?.close()
                        try? stderrHandle?.close()
                        _ = writer.write(.end)
                    }

                    func drainAvailableLogs() throws -> Bool {
                        var wroteAny = false

                        if wantStdout, let stdoutHandle {
                            while true {
                                guard let data = try stdoutHandle.read(upToCount: 4096), !data.isEmpty else { break }
                                writeLogChunk(
                                    data,
                                    streamType: .stdout,
                                    ttyMode: isTTY,
                                    query: query,
                                    writer: writer
                                )
                                wroteAny = true
                            }
                        }

                        if wantStderr, let stderrHandle {
                            while true {
                                guard let data = try stderrHandle.read(upToCount: 4096), !data.isEmpty else { break }
                                writeLogChunk(
                                    data,
                                    streamType: .stderr,
                                    ttyMode: isTTY,
                                    query: query,
                                    writer: writer
                                )
                                wroteAny = true
                            }
                        }

                        return wroteAny
                    }

                    guard wantStdout || wantStderr else {
                        return
                    }

                    do {
                        if let replayLogPath {
                            let streamType: DockerStreamFrame.StreamType = wantStdout ? .stdout : .stderr
                            var offset = 0

                            while true {
                                if let replayData = FileManager.default.contents(atPath: replayLogPath),
                                    replayData.count > offset
                                {
                                    let delta = replayData.subdata(in: offset..<replayData.count)
                                    offset = replayData.count
                                    writeLogChunk(
                                        delta,
                                        streamType: streamType,
                                        ttyMode: isTTY,
                                        query: query,
                                        writer: writer
                                    )
                                }

                                if !follow {
                                    return
                                }

                                if try await isContainerRunning(id: id, client: client) {
                                    try await Swift.Task.sleep(nanoseconds: 200_000_000)
                                    continue
                                }

                                // Give the host-side log file a brief chance to flush
                                // after exit before closing the follow stream.
                                try await Swift.Task.sleep(nanoseconds: 400_000_000)
                                if let finalData = FileManager.default.contents(atPath: replayLogPath),
                                    finalData.count > offset
                                {
                                    let delta = finalData.subdata(in: offset..<finalData.count)
                                    writeLogChunk(
                                        delta,
                                        streamType: streamType,
                                        ttyMode: isTTY,
                                        query: query,
                                        writer: writer
                                    )
                                }
                                return
                            }
                        }

                        _ = try drainAvailableLogs()
                        if !follow {
                            return
                        }

                        var emptyPolls = 0
                        do {
                            while true {
                                let wrote = try drainAvailableLogs()
                                if wrote {
                                    emptyPolls = 0
                                } else {
                                    emptyPolls += 1
                                }

                                if try await isContainerRunning(id: id, client: client) {
                                    try await Swift.Task.sleep(nanoseconds: 200_000_000)
                                    continue
                                }

                                if emptyPolls >= 2 {
                                    break
                                }
                                try await Swift.Task.sleep(nanoseconds: 200_000_000)
                            }
                        } catch {
                            return
                        }
                    } catch {
                        return
                    }
                }
            }

            return Response(
                status: .ok,
                headers: ["Content-Type": contentType],
                body: body
            )
        }
    }
}
