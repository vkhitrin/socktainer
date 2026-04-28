import Vapor

struct AuthRoute: RouteCollection {
    let client: ClientRegistryService
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/auth", use: AuthRoute.handler(client: client))
    }
}

extension AuthRoute {
    private static func unauthorized(_ message: String) throws -> Response {
        try jsonResponse(status: .unauthorized, message: message)
    }

    private static func jsonResponse(status: HTTPResponseStatus, message: String) throws -> Response {
        let response = try Response(
            status: status,
            body: .init(data: JSONEncoder().encode(DockerErrorResponse(message: message)))
        )
        response.headers.replaceOrAdd(name: .contentType, value: "application/json")
        return response
    }

    static func handler(client: ClientRegistryService) -> @Sendable (Request) async throws -> Response {
        { req in
            // Collect the body for large requests
            let collectedBuffer = try await req.body.collect().get()

            if let buffer = collectedBuffer {
                _ = buffer.getString(at: 0, length: buffer.readableBytes)

                if let data = buffer.getData(at: 0, length: buffer.readableBytes) {
                    do {
                        _ = try JSONDecoder().decode(AuthConfig.self, from: data)
                    } catch {
                        req.logger.error("Failed to decode content from buffer: \(error)")
                    }
                }
            }

            do {
                let authConfig = try req.content.decode(AuthConfig.self)

                guard
                    let username = authConfig.username, !username.isEmpty,
                    let password = authConfig.password, !password.isEmpty,
                    let serverAddress = authConfig.serveraddress, !serverAddress.isEmpty
                else {
                    return try unauthorized("Invalid authentication payload")
                }

                let logger = req.logger

                do {
                    // Perform complete login process (validation + storage)
                    let identityToken = try await client.login(
                        serverAddress: serverAddress,
                        username: username,
                        password: password,
                        logger: logger
                    )

                    if identityToken.isEmpty {
                        return Response(status: .noContent)
                    }

                    let response = SystemAuthResponse(status: "Login Succeeded", identityToken: identityToken)
                    return try await response.encodeResponse(status: .ok, for: req)

                } catch ClientRegistryError.invalidServerAddress {
                    return try unauthorized("Invalid server address")

                } catch ClientRegistryError.invalidCredentials {
                    return try unauthorized("Invalid credentials format")

                } catch ClientRegistryError.authenticationFailed(let message) {
                    return try unauthorized(message)

                } catch ClientRegistryError.storageError(let message) {
                    logger.error("Failed to store credentials: \(message)")
                    return try jsonResponse(status: .internalServerError, message: "Failed to store credentials")

                } catch {
                    logger.error("Unexpected registry error: \(error)")
                    return try jsonResponse(status: .internalServerError, message: "Internal server error")
                }

            } catch let DecodingError.dataCorrupted(context) {
                return try unauthorized("Invalid JSON: \(context.debugDescription)")
            } catch let DecodingError.keyNotFound(key, _) {
                return try unauthorized("Missing required field: \(key.stringValue)")
            } catch let DecodingError.typeMismatch(_, context) {
                return try unauthorized("Invalid JSON: \(context.debugDescription)")
            } catch let DecodingError.valueNotFound(_, context) {
                return try unauthorized("Invalid JSON: \(context.debugDescription)")
            } catch {
                return try unauthorized("Invalid authentication payload")
            }
        }
    }
}
