import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

struct ContainerArchiveRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.getHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
        try routes.registerVersionedRoute(
            .PUT,
            pattern: "/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.putHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
        try routes.registerVersionedRoute(
            .HEAD,
            pattern: "/containers/{id:.*}/archive",
            use: ContainerArchiveRoute.headHandler(containerClient: containerClient, archiveClient: archiveClient)
        )
    }

    private static func containerID(from request: Request) throws -> String {
        guard let id = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing container ID")
        }
        return id
    }

    private static func container(
        for id: String,
        using containerClient: ClientContainerProtocol
    ) async throws -> ContainerSnapshot {
        guard let container = try await containerClient.getContainer(id: id) else {
            throw Abort(.notFound, reason: "No such container: \(id)")
        }
        return container
    }

    private static func archiveErrorAbort(_ error: ClientArchiveError, containerID: String) -> Abort {
        switch error {
        case .containerNotFound:
            return Abort(.notFound, reason: "No such container: \(containerID)")
        case .pathNotFound:
            return Abort(.notFound, reason: error.localizedDescription)
        case .invalidPath:
            return Abort(.badRequest, reason: error.localizedDescription)
        default:
            return Abort(.internalServerError, reason: error.localizedDescription)
        }
    }

    private static func statHeaderValue(_ stat: PathStat) throws -> String {
        try JSONEncoder().encode(stat).base64EncodedString()
    }

    /// GET /containers/{id}/archive - Get a tar archive of a resource in the filesystem of container id
    static func getHandler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            let id = try containerID(from: req)
            let query = try req.query.decode(ContainerArchiveInfoQuery.self)
            let container = try await container(for: id, using: containerClient)

            do {
                let (tarData, stat) = try await archiveClient.getArchive(containerId: container.id, path: query.path)

                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/x-tar")
                headers.add(name: .contentLength, value: String(tarData.count))
                headers.add(name: "X-Docker-Container-Path-Stat", value: try statHeaderValue(stat))

                // NOTE: Apple container's archive API returns the tar payload that
                // socktainer streams back here. The route is functionally aligned,
                // but exact Moby tar/compression details depend on the backend.
                return Response(
                    status: .ok,
                    headers: headers,
                    body: .init(data: tarData)
                )
            } catch let error as ClientArchiveError {
                throw archiveErrorAbort(error, containerID: id)
            }
        }
    }

    /// PUT /containers/{id}/archive - Extract an archive of files or folders to a directory in a container
    static func putHandler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            let id = try containerID(from: req)

            let query = try req.query.decode(PutContainerArchiveQuery.self)
            if let contentType = req.headers.first(name: .contentType),
                !contentType.isEmpty,
                !contentType.lowercased().hasPrefix("application/x-tar"),
                !contentType.lowercased().hasPrefix("application/octet-stream")
            {
                throw Abort(.badRequest, reason: "Content-Type must be application/x-tar or application/octet-stream")
            }
            let container = try await container(for: id, using: containerClient)

            // NOTE: Apple container's archive extraction API consumes a tarball
            // path, not a streaming reader. Buffer the upload to a temporary tar
            // file first, which keeps the route compatible but limits exact
            // Docker-style streaming archive semantics.
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let tarPath = tempDir.appendingPathComponent("archive.tar")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            try await RequestBodyFileUtility.writeRequestBody(
                req,
                to: tarPath,
                failureReason: "Failed to process archive upload"
            )

            do {
                // NOTE: The current unpack path already applies tar owner/group
                // metadata during extraction. Accept copyUIDGID instead of
                // rejecting it, even though extraction is still buffered through
                // a temporary tarball and broader archive-write fidelity remains
                // best-effort.
                _ = query.copyUIDGID

                try await archiveClient.putArchive(
                    containerId: container.id,
                    path: query.path,
                    tarPath: tarPath,
                    noOverwriteDirNonDir: (query.noOverwriteDirNonDir?.lowercased()).map { ["1", "true", "yes", "on"].contains($0) } ?? false,
                    containerIsRunning: container.status == .running
                )

                return Response(status: .ok)
            } catch let error as ClientArchiveError {
                throw archiveErrorAbort(error, containerID: id)
            }
        }
    }

    /// HEAD /containers/{id}/archive - Get information about files in a container
    static func headHandler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol
    ) -> @Sendable (Request) async throws -> Response {
        { req in
            let id = try containerID(from: req)
            let query = try req.query.decode(ContainerArchiveInfoQuery.self)
            let container = try await container(for: id, using: containerClient)

            do {
                let stat = try await archiveClient.statPath(containerId: container.id, path: query.path)

                var headers = HTTPHeaders()
                headers.add(name: "X-Docker-Container-Path-Stat", value: try statHeaderValue(stat))

                // NOTE: Vapor auto-adds `Content-Length: 0` for empty responses.
                // Real Docker omits that header on this HEAD path, so raw header
                // parity here remains framework-limited even though the stat payload
                // itself is aligned more closely now.
                return Response(status: .ok, headers: headers)
            } catch let error as ClientArchiveError {
                throw archiveErrorAbort(error, containerID: id)
            }
        }
    }
}
