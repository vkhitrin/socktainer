import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Vapor

struct ImageCreateRoute: RouteCollection {
    let client: ClientImageProtocol
    let registryClient: ClientRegistryProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/create", use: ImageCreateRoute.handler(client: client, registryClient: registryClient))
    }
}

extension ImageCreateRoute {
    private static func dockerPullStatusLine(_ status: String, id: String? = nil) -> String {
        var payload: [String: String] = ["status": status]
        if let id, !id.isEmpty {
            payload["id"] = id
        }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data ?? Data("{\"status\":\"\(status)\"}".utf8), encoding: .utf8) ?? "{\"status\":\"\(status)\"}"
    }

    private static func resolvedPullReference(image: String, tag: String) throws -> String {
        let parsedReference = try Reference.parse(image)
        if parsedReference.digest != nil {
            return try ClientImage.normalizeReference(parsedReference.description)
        }
        guard !tag.isEmpty else {
            return try ClientImage.normalizeReference(image)
        }
        if tag.starts(with: "sha256:") {
            return try ClientImage.normalizeReference(try parsedReference.withDigest(tag).description)
        }
        return try ClientImage.normalizeReference(try parsedReference.withTag(tag).description)
    }

    private static func broadcastPullEvent(
        req: Request,
        pullReference: String
    ) async {
        guard let broadcaster = req.eventBroadcaster else {
            return
        }

        let resolvedImage = try? await ClientImage.get(reference: pullReference)
        let imageLabels = try? await resolvedImage?.config(for: currentPlatform()).config?.labels
        let event = DockerEvent.simpleEvent(
            id: resolvedImage?.digest ?? pullReference,
            type: "image",
            status: "pull",
            from: resolvedImage?.reference ?? pullReference,
            name: pullReference,
            image: resolvedImage?.reference ?? pullReference,
            labels: imageLabels ?? [:]
        )
        await broadcaster.broadcast(event)
    }

    private static func tagImportedImages(_ importedRefs: [String], repo: String?, tag: String?) async throws {
        guard let repo, !repo.isEmpty, let importedRef = importedRefs.first else {
            return
        }

        let targetReference: String = try {
            if let tag, !tag.isEmpty {
                return try ClientImage.normalizeReference("\(repo):\(tag)")
            }
            return try ClientImage.normalizeReference(repo)
        }()

        let sourceImage = try await ClientImage.get(reference: importedRef)
        _ = try await sourceImage.tag(new: targetReference)
    }

    private static func loadImportedImage(
        req: Request,
        client: ClientImageProtocol,
        platform: Platform,
        fromSrc: String,
        repo: String?,
        tag: String?,
        message: String?,
        changes: [String]
    ) async throws -> Response {
        guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
            throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let tarPath = tempDir.appendingPathComponent("import.tar")

        if fromSrc == "-" {
            let bodyBuffer: ByteBuffer
            if let data = req.body.data {
                bodyBuffer = data
            } else {
                var collectedBuffer = ByteBufferAllocator().buffer(capacity: 0)
                for try await chunk in req.body {
                    var chunkBuffer = chunk
                    collectedBuffer.writeBuffer(&chunkBuffer)
                }
                bodyBuffer = collectedBuffer
            }

            guard bodyBuffer.readableBytes > 0 else {
                throw Abort(.badRequest, reason: "Request body is required when fromSrc is '-'")
            }
            try Data(buffer: bodyBuffer).write(to: tarPath)
        } else {
            guard let remoteURL = URL(string: fromSrc), let scheme = remoteURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw Abort(.badRequest, reason: "fromSrc must be '-' or an http/https URL")
            }

            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw Abort(.badRequest, reason: "Failed to download image import source")
            }
            try data.write(to: tarPath)
        }

        let loadedImages: [String]
        do {
            loadedImages = try await client.load(
                tarballPath: tarPath,
                platform: platform,
                appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                importMessage: message,
                importChanges: changes,
                logger: req.logger
            )
        } catch let error as ContainerImageUtility.Error {
            switch error {
            case .invalidImportChange(let reason):
                throw Abort(.badRequest, reason: reason)
            case .invalidTarball:
                throw error
            }
        }
        try await tagImportedImages(loadedImages, repo: repo, tag: tag)

        if let broadcaster = req.eventBroadcaster {
            for image in loadedImages {
                let resolvedImage = try? await ClientImage.get(reference: image)
                let imageLabels = try? await resolvedImage?.config(for: currentPlatform()).config?.labels
                let event = DockerEvent.simpleEvent(
                    id: resolvedImage?.digest ?? image,
                    type: "image",
                    status: "import",
                    from: resolvedImage?.reference ?? image,
                    name: image,
                    image: resolvedImage?.reference ?? image,
                    labels: imageLabels ?? [:]
                )
                await broadcaster.broadcast(event)
            }
        }

        let response = Response()
        response.headers.add(name: .contentType, value: "application/json")
        response.body = .init(stream: { writer in
            Swift.Task {
                for image in loadedImages {
                    _ = writer.write(.buffer(ByteBuffer(string: "{\"status\": \"Loaded image \(image.replacingOccurrences(of: "\"", with: "\\\""))\"}\n")))
                }
                _ = writer.write(.end)
            }
        })
        return response
    }

    static func handler(client: ClientImageProtocol, registryClient: ClientRegistryProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(ImageCreateQuery.self)
            let image = query.fromImage ?? ""
            let fromSrc = query.fromSrc ?? ""
            let tag = query.tag ?? ""
            let decodedTag = tag.removingPercentEncoding ?? tag
            let platformString = query.platform
            let platform: Platform
            if let platformString, !platformString.isEmpty {
                platform = try platformOrThrow(platformString)
            } else {
                platform = currentPlatform()
            }

            if !image.isEmpty && !fromSrc.isEmpty {
                throw Abort(.badRequest, reason: "fromImage and fromSrc are mutually exclusive")
            }
            if image.isEmpty && fromSrc.isEmpty {
                throw Abort(.badRequest, reason: "Either fromImage or fromSrc must be provided")
            }

            if !image.isEmpty {
                if let repo = query.repo, !repo.isEmpty {
                    throw Abort(.badRequest, reason: "repo may only be used when importing from fromSrc")
                }
                if let message = query.message, !message.isEmpty {
                    throw Abort(.badRequest, reason: "message may only be used when importing from fromSrc")
                }
                if let changes = query.changes, !changes.isEmpty {
                    throw Abort(.badRequest, reason: "changes may only be used when importing from fromSrc")
                }

                let parsedReference = try Reference.parse(image)
                _ = parsedReference
            }

            if !fromSrc.isEmpty {
                return try await loadImportedImage(
                    req: req,
                    client: client,
                    platform: platform,
                    fromSrc: fromSrc,
                    repo: query.repo,
                    tag: decodedTag.isEmpty ? nil : decodedTag,
                    message: query.message,
                    changes: query.changes ?? []
                )
            }

            let registryAuth = try RegistryAuthUtility.parseSingleHeader(req.headers.first(name: "X-Registry-Auth"))
            if let auth = registryAuth {
                _ = try await registryClient.login(
                    serverAddress: auth.server,
                    username: auth.username,
                    password: auth.password,
                    logger: req.logger
                )
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(stream: { writer in
                Swift.Task {
                    do {
                        let pullTags: [String]
                        let parsedReference = try Reference.parse(image)
                        if decodedTag.isEmpty, parsedReference.tag == nil, parsedReference.digest == nil {
                            // Docker treats an empty pull tag as "all tags". Apple
                            // does not expose that directly, so socktainer resolves
                            // tags via the registry API and pulls them one by one.
                            pullTags = try await registryClient.listTags(
                                reference: image,
                                credentialsOverride: registryAuth.map { ($0.username, $0.password) },
                                logger: req.logger
                            )
                            if pullTags.isEmpty {
                                throw Abort(.notFound, reason: "No tags found for image: \(image)")
                            }
                        } else {
                            pullTags = [decodedTag]
                        }

                        for pullTag in pullTags {
                            let pullReference = try resolvedPullReference(image: image, tag: pullTag)
                            let existedBeforePull = (try? await ClientImage.get(reference: pullReference)) != nil
                            let progressStream = try await client.pull(
                                image: image,
                                tag: pullTag,
                                platform: platform,
                                logger: req.logger
                            )

                            for try await progress in progressStream {
                                let progressLine = dockerPullStatusLine(progress, id: pullTag)
                                _ = writer.write(.buffer(ByteBuffer(string: progressLine + "\n")))
                            }
                            let resolvedImage = try await ClientImage.get(reference: pullReference)
                            let digestLine = dockerPullStatusLine("Digest: \(resolvedImage.digest)")
                            _ = writer.write(.buffer(ByteBuffer(string: digestLine + "\n")))
                            let finalStatus =
                                existedBeforePull
                                ? "Status: Image is up to date for \(resolvedImage.reference)"
                                : "Status: Downloaded newer image for \(resolvedImage.reference)"
                            let statusLine = dockerPullStatusLine(finalStatus)
                            _ = writer.write(.buffer(ByteBuffer(string: statusLine + "\n")))
                            await broadcastPullEvent(req: req, pullReference: pullReference)
                        }
                        _ = writer.write(.end)
                    } catch {
                        let message = String(describing: error).replacingOccurrences(of: "\"", with: "\\\"")
                        _ = writer.write(.buffer(ByteBuffer(string: "{\"error\": \"\(message)\"}\n")))
                        _ = writer.write(.error(error))
                    }
                }
            })
            return response
        }
    }
}
