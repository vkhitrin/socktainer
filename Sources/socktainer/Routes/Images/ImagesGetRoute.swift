import ContainerAPIClient
import Containerization
import Foundation
import Vapor

struct ImagesGetRoute: RouteCollection {
    let client: ClientImageProtocol

    init(client: ClientImageProtocol) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/images/get", use: ImagesGetRoute.handlerMultiple(client: client))
        try routes.registerVersionedRoute(.GET, pattern: "/images/{name:.*}/get", use: ImagesGetRoute.handlerSingle(client: client))
    }

    static func handlerSingle(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Image name is required")
            }

            return try await saveImages(references: [name], req: req, client: client)
        }
    }

    static func handlerMultiple(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let names = try? req.query.get([String].self, at: "names")

            guard let names = names, !names.isEmpty else {
                throw Abort(.badRequest, reason: "At least one image name is required in 'names' query parameter")
            }

            return try await saveImages(references: names, req: req, client: client)
        }
    }

    private static func saveImages(references: [String], req: Request, client: ClientImageProtocol) async throws -> Response {
        let platformString = try? req.query.get(String.self, at: "platform")
        let platform = try platformString.map(platformOrThrow)

        guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
            throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
        }

        let tarballPath: URL
        do {
            tarballPath = try await client.save(references: references, platform: platform, appleContainerAppSupportUrl: appleContainerAppSupportUrl, logger: req.logger)
        } catch let error as ClientImageError {
            switch error {
            case .notFound(let id):
                throw Abort(.notFound, reason: "No such image: \(id)")
            case .inUse(let id):
                throw Abort(.conflict, reason: "Image is in use: \(id)")
            }
        }
        let tempDir = tarballPath.deletingLastPathComponent()

        if let broadcaster = req.eventBroadcaster {
            for reference in references {
                let resolvedImage = try? await ClientImage.get(reference: reference)
                let imageLabels = try? await resolvedImage?.config(for: currentPlatform()).config?.labels
                let event = DockerEvent.simpleEvent(
                    id: resolvedImage?.digest ?? reference,
                    type: "image",
                    status: "save",
                    from: resolvedImage?.reference ?? reference,
                    name: reference,
                    image: resolvedImage?.reference ?? reference,
                    labels: imageLabels ?? [:]
                )
                await broadcaster.broadcast(event)
            }
        }

        return try streamTarball(
            at: tarballPath,
            tempDir: tempDir,
            logger: req.logger
        )
    }

    private static func streamTarball(
        at tarballPath: URL,
        tempDir: URL,
        logger: Logger
    ) throws -> Response {
        let attributes = try FileManager.default.attributesOfItem(atPath: tarballPath.path)
        let contentLength = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/x-tar")
        headers.replaceOrAdd(name: .contentLength, value: String(contentLength))
        headers.replaceOrAdd(name: "Docker-Experimental", value: "false")
        headers.replaceOrAdd(name: "Ostype", value: "linux")

        let body = Response.Body(stream: { writer in
            _ = Swift.Task.detached(priority: .utility) {
                defer {
                    try? FileManager.default.removeItem(at: tempDir)
                }

                do {
                    let handle = try FileHandle(forReadingFrom: tarballPath)
                    defer { try? handle.close() }

                    while autoreleasepool(invoking: {
                        guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                            return false
                        }

                        var buffer = ByteBufferAllocator().buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        _ = writer.write(.buffer(buffer))
                        return true
                    }) {}

                    _ = writer.write(.end)
                } catch {
                    logger.error("Failed to stream image tarball: \(error)")
                    _ = writer.write(.error(error))
                }
            }
        })

        return Response(status: .ok, headers: headers, body: body)
    }
}
