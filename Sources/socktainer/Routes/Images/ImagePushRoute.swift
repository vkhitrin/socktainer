import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Vapor

struct ImagePushRoute: RouteCollection {
    let client: ClientImageProtocol
    let registryClient: ClientRegistryProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/{name:.*}/push", use: ImagePushRoute.handler(client: client, registryClient: registryClient))
    }
}

extension ImagePushRoute {
    private static func resolvedReference(imageName: String, tag: String?) throws -> String {
        guard let tag, !tag.isEmpty else {
            return imageName
        }

        let parsedReference = try Reference.parse(imageName)
        if tag.starts(with: "sha256:") {
            return try parsedReference.withDigest(tag).description
        }
        return try parsedReference.withTag(tag).description
    }

    private static func escapeJSONString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func progressJSONLine(event: ClientImagePushEvent) -> String {
        switch event {
        case .banner(let message):
            let escapedMessage = escapeJSONString(message)
            return "{\"status\":\"\(escapedMessage)\"}"
        case .preparing(let id):
            let escapedID = escapeJSONString(id)
            return "{\"status\":\"Preparing\",\"progressDetail\":{},\"id\":\"\(escapedID)\"}"
        case .unavailable(let id):
            let escapedID = escapeJSONString(id)
            return "{\"status\":\"Unavailable\",\"progressDetail\":{},\"id\":\"\(escapedID)\"}"
        case .pushing(let id, let current, let total):
            let escapedID = escapeJSONString(id)
            let progress = escapeJSONString(ByteCountFormatter.string(fromByteCount: current, countStyle: .file))
            return "{\"status\":\"Pushing\",\"progressDetail\":{\"current\":\(current),\"total\":\(total)},\"progress\":\"\(progress)\",\"id\":\"\(escapedID)\"}"
        case .pushed(let id):
            let escapedID = escapeJSONString(id)
            return "{\"status\":\"Pushed\",\"id\":\"\(escapedID)\"}"
        }
    }

    private static func errorJSONLine(_ message: String) -> String {
        let escaped = escapeJSONString(message)
        return "{\"errorDetail\":{\"message\":\"\(escaped)\"},\"error\":\"\(escaped)\"}"
    }

    private static func dockerizedPushErrorMessage(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("401 unauthorized")
            || lowercased.contains("insufficient_scope")
            || lowercased.contains("access denied")
        {
            return "push access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed"
        }
        return message
    }

    private static func pushRepositoryBanner(reference: String) -> String {
        do {
            let parsed = try Reference.parse(reference)
            let repository: String
            if let domain = parsed.domain, !domain.isEmpty {
                repository = "\(domain)/\(parsed.path)"
            } else {
                repository = parsed.path
            }
            return "The push refers to repository [\(repository)]"
        } catch {
            return "The push refers to repository [\(reference)]"
        }
    }

    static func handler(client: ClientImageProtocol, registryClient: ClientRegistryProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let imageName = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            do {
                let query = try req.query.decode(ImagePushQuery.self)
                let reference = try resolvedReference(imageName: imageName, tag: query.tag)
                guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                    throw Abort(.internalServerError, reason: "Apple Container application support URL is not configured")
                }

                let platform: Platform?
                if let platformString = query.platform, !platformString.isEmpty {
                    platform = try platformOrThrow(platformString)
                } else {
                    platform = nil
                }

                if let auth = try RegistryAuthUtility.parseSingleHeader(req.headers.first(name: "X-Registry-Auth")) {
                    let credentialsValid = try await registryClient.validateCredentials(
                        serverAddress: auth.server,
                        username: auth.username,
                        password: auth.password
                    )
                    guard credentialsValid else {
                        throw Abort(.unauthorized, reason: "Invalid registry credentials")
                    }
                }

                let response = Response()
                response.headers.add(name: .contentType, value: "application/json")

                // NOTE: This route targets the classic Docker Engine push flow,
                // not `buildx`/BuildKit exporter output.
                // Apple container exposes push progress as backend-specific
                // textual updates. socktainer maps them into Docker-shaped JSON
                // status lines, but exact Moby progress framing still depends on
                // backend behavior that is not available here.
                let progressStream = try await client.push(
                    imageName: imageName,
                    tag: query.tag,
                    platform: platform,
                    appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                    logger: req.logger
                )

                response.body = .init(stream: { writer in
                    Swift.Task {
                        var preparedIDs: [String] = []
                        do {
                            var emittedLines = Set<String>()
                            for try await progress in progressStream {
                                if case .preparing(let id) = progress {
                                    preparedIDs.append(id)
                                }
                                let line = progressJSONLine(event: progress)
                                guard emittedLines.insert(line).inserted else {
                                    continue
                                }
                                _ = writer.write(.buffer(ByteBuffer(string: line + "\n")))
                            }
                            if let broadcaster = req.eventBroadcaster {
                                let resolvedImage = try? await ClientImage.get(reference: reference)
                                let imageLabels = try? await resolvedImage?.config(for: currentPlatform()).config?.labels
                                let event = DockerEvent.simpleEvent(
                                    id: resolvedImage?.digest ?? reference,
                                    type: "image",
                                    status: "push",
                                    from: resolvedImage?.reference ?? reference,
                                    name: reference,
                                    image: resolvedImage?.reference ?? reference,
                                    labels: imageLabels ?? [:]
                                )
                                await broadcaster.broadcast(event)
                            }
                            _ = writer.write(.end)
                        } catch {
                            let mappedMessage = dockerizedPushErrorMessage(error.localizedDescription)
                            if mappedMessage != error.localizedDescription {
                                for id in preparedIDs {
                                    let unavailableLine = progressJSONLine(event: .unavailable(id: id))
                                    _ = writer.write(.buffer(ByteBuffer(string: unavailableLine + "\n")))
                                }
                            }
                            _ = writer.write(.buffer(ByteBuffer(string: errorJSONLine(mappedMessage) + "\n")))
                            _ = writer.write(.error(error))
                        }
                    }
                })
                return response
            } catch let error as ClientImageError {
                switch error {
                case .notFound(let id):
                    let query = try req.query.decode(ImagePushQuery.self)
                    let reference = try resolvedReference(imageName: imageName, tag: query.tag)
                    let response = Response()
                    response.headers.add(name: .contentType, value: "application/json")
                    response.body = .init(stream: { writer in
                        Swift.Task {
                            let banner = progressJSONLine(event: .banner(pushRepositoryBanner(reference: reference)))
                            _ = writer.write(.buffer(ByteBuffer(string: banner + "\n")))
                            var imageDisplayName = id.replacingOccurrences(of: "docker.io/library/", with: "")
                            if imageDisplayName.hasSuffix(":latest") {
                                imageDisplayName.removeLast(":latest".count)
                            }
                            let message = "An image does not exist locally with the tag: \(imageDisplayName)"
                            _ = writer.write(.buffer(ByteBuffer(string: errorJSONLine(message) + "\n")))
                            _ = writer.write(.end)
                        }
                    })
                    return response
                case .inUse:
                    throw Abort(.conflict, reason: error.localizedDescription)
                }
            } catch let error as AbortError {
                throw error
            } catch {
                throw Abort(.internalServerError, reason: "\(error)")
            }
        }
    }
}
