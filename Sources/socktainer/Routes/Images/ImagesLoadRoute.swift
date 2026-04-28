import ContainerAPIClient
import Foundation
import Vapor

struct ImagesLoadRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/images/load", use: ImagesLoadRoute.handler(client: client))
    }
}

extension ImagesLoadRoute {
    private static func errorResponse(_ reason: String) -> Response {
        let response = Response(status: .internalServerError)
        response.headers.replaceOrAdd(name: .contentType, value: "application/json")
        response.body = .init(string: "{\"message\":\(reason.debugDescription)}\n")
        return response
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(ImageLoadQuery.self)
            let quiet = query.quiet ?? false

            let platform: Platform?
            if let platformString = query.platform, !platformString.isEmpty {
                platform = try platformOrThrow(platformString)
            } else {
                platform = nil
            }

            if let contentType = req.headers.first(name: .contentType) {
                let normalized = contentType.lowercased()
                if !normalized.hasPrefix("application/x-tar")
                    && !normalized.hasPrefix("application/octet-stream")
                {
                    throw Abort(.badRequest, reason: "Content-Type must be application/x-tar or application/octet-stream")
                }
            }

            guard let appleContainerAppSupportUrl = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                return errorResponse("AppleContainerAppSupportUrl not configured")
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let tarPath = tempDir.appendingPathComponent("images.tar")
            try await RequestBodyFileUtility.writeRequestBody(
                req,
                to: tarPath,
                failureReason: "Failed to process image load upload"
            )

            do {
                var responseLines: [String] = []

                let loadedImages = try await client.load(
                    tarballPath: tarPath,
                    platform: platform,
                    appleContainerAppSupportUrl: appleContainerAppSupportUrl,
                    importMessage: nil,
                    importChanges: [],
                    logger: req.logger
                )

                for image in loadedImages {
                    // Docker still emits a "Loaded image: ..." stream record here
                    // even when the request carries `quiet=1`, so keep the user-
                    // visible response aligned with the engine instead of treating
                    // `quiet` as a hard suppression toggle.
                    _ = quiet
                    responseLines.append("{\"stream\":\"Loaded image: \(image)\\n\"}")
                    if let broadcaster = req.eventBroadcaster {
                        let resolvedImage = try? await ClientImage.get(reference: image)
                        let imageLabels = try? await resolvedImage?.config(for: currentPlatform()).config?.labels
                        let event = DockerEvent.simpleEvent(
                            id: resolvedImage?.digest ?? image,
                            type: "image",
                            status: "load",
                            from: resolvedImage?.reference ?? image,
                            name: image,
                            image: resolvedImage?.reference ?? image,
                            labels: imageLabels ?? [:]
                        )
                        await broadcaster.broadcast(event)
                    }
                }

                let response = Response(status: .ok)
                response.headers.replaceOrAdd(name: .contentType, value: "application/json")
                response.body = .init(string: responseLines.joined(separator: "\n") + (responseLines.isEmpty ? "" : "\n"))
                return response
            } catch {
                if let abort = error as? AbortError {
                    throw abort
                }
                req.logger.error("Failed to load images: \(error)")
                return errorResponse(error.localizedDescription)
            }
        }
    }
}
