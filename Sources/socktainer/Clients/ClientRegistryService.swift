import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Logging

protocol ClientRegistryProtocol: Sendable {
    func validateCredentials(serverAddress: String, username: String, password: String) async throws -> Bool
    func storeCredentials(serverAddress: String, username: String, password: String, logger: Logger) async throws
    func retrieveCredentials(serverAddress: String, logger: Logger) async throws -> Authentication?
    func login(serverAddress: String, username: String, password: String, logger: Logger) async throws -> String
    func listTags(reference: String, credentialsOverride: (username: String, password: String)?, logger: Logger) async throws -> [String]
}

enum ClientRegistryError: Error {
    case invalidServerAddress
    case invalidCredentials
    case authenticationFailed(String)
    case storageError(String)
}

extension ClientRegistryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return "Invalid registry server address"
        case .invalidCredentials:
            return "Invalid registry credentials"
        case .authenticationFailed(let message):
            return message
        case .storageError(let message):
            return message
        }
    }
}

extension ClientRegistryError: CustomStringConvertible {
    var description: String {
        errorDescription ?? "Unknown registry error"
    }
}

// WARN: There is no option to remove entry from keychain when client logs out.
struct ClientRegistryService: ClientRegistryProtocol {
    private struct RegistryReferenceContext {
        let host: String
        let repositoryPath: String
        let scheme: String
    }

    private struct RegistryTagsListResponse: Decodable {
        let name: String?
        let tags: [String]?
    }

    private struct RegistryTokenResponse: Decodable {
        let token: String?
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case token
            case accessToken = "access_token"
        }
    }

    private struct BearerChallenge {
        let realm: String
        let service: String
        let scope: String?
    }

    let keychainEntryId = Constants.keychainID

    // (workaround) normalize server address to match `container` CLI behavior
    private func normalizeServerAddress(_ serverAddress: String) -> String {
        if serverAddress == "https://index.docker.io/v1/" {
            return "registry-1.docker.io"
        }
        return serverAddress
    }

    private func discoverContainerCLIPath() -> String? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in pathDirectories {
            let candidatePath = URL(fileURLWithPath: directory).appendingPathComponent("container").path
            guard FileManager.default.isExecutableFile(atPath: candidatePath) else {
                continue
            }

            return URL(fileURLWithPath: candidatePath).resolvingSymlinksInPath().path
        }

        return nil
    }

    private func resolveRegistryReference(_ reference: String) throws -> RegistryReferenceContext {
        let parsedReference = try Reference.parse(reference)
        let host = parsedReference.resolvedDomain ?? Reference.resolveDomain(domain: "docker.io")
        let scheme = try RequestScheme.auto.schemeFor(host: host).rawValue

        var repositoryPath = parsedReference.path
        if host == "registry-1.docker.io" || host == "docker.io" {
            if !repositoryPath.contains("/") {
                repositoryPath = "library/\(repositoryPath)"
            }
        }

        return RegistryReferenceContext(host: host, repositoryPath: repositoryPath, scheme: scheme)
    }

    private func parseBearerChallenge(_ value: String?) -> BearerChallenge? {
        guard let value, value.lowercased().hasPrefix("bearer ") else {
            return nil
        }

        let pattern = #"([A-Za-z]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        var fields: [String: String] = [:]
        for match in matches where match.numberOfRanges == 3 {
            let key = nsValue.substring(with: match.range(at: 1)).lowercased()
            let fieldValue = nsValue.substring(with: match.range(at: 2))
            fields[key] = fieldValue
        }

        guard let realm = fields["realm"], let service = fields["service"] else {
            return nil
        }

        return BearerChallenge(realm: realm, service: service, scope: fields["scope"])
    }

    private func makeURL(for context: RegistryReferenceContext, path: String) throws -> URL {
        guard let url = URL(string: "\(context.scheme)://\(context.host)\(path)") else {
            throw ClientRegistryError.invalidServerAddress
        }
        return url
    }

    private func makeTagsListRequest(
        url: URL,
        authorization: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func fetchRegistryToken(
        challenge: BearerChallenge,
        repositoryPath: String,
        authentication: Authentication?
    ) async throws -> String {
        guard var components = URLComponents(string: challenge.realm) else {
            throw ClientRegistryError.invalidServerAddress
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "service", value: challenge.service))
        queryItems.append(URLQueryItem(name: "scope", value: challenge.scope ?? "repository:\(repositoryPath):pull"))
        queryItems.append(URLQueryItem(name: "client_id", value: "socktainer"))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ClientRegistryError.invalidServerAddress
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let authentication {
            request.setValue(try await authentication.token(), forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw ClientRegistryError.storageError("Registry token request failed")
        }

        let tokenResponse = try JSONDecoder().decode(RegistryTokenResponse.self, from: data)
        if let token = tokenResponse.token, !token.isEmpty {
            return "Bearer \(token)"
        }
        if let token = tokenResponse.accessToken, !token.isEmpty {
            return "Bearer \(token)"
        }

        throw ClientRegistryError.storageError("Registry token response did not contain a token")
    }

    private func executeTagsListRequest(
        context: RegistryReferenceContext,
        authentication: Authentication?
    ) async throws -> [String] {
        let url = try makeURL(for: context, path: "/v2/\(context.repositoryPath)/tags/list")
        let basicAuthorization = try await authentication?.token()
        let initialRequest = makeTagsListRequest(url: url, authorization: basicAuthorization)
        let (initialData, initialResponse) = try await URLSession.shared.data(for: initialRequest)

        guard let initialHTTPResponse = initialResponse as? HTTPURLResponse else {
            throw ClientRegistryError.storageError("Registry tags response was not HTTP")
        }

        if (200..<300).contains(initialHTTPResponse.statusCode) {
            let decoded = try JSONDecoder().decode(RegistryTagsListResponse.self, from: initialData)
            return decoded.tags ?? []
        }

        if initialHTTPResponse.statusCode == 401 || initialHTTPResponse.statusCode == 403 {
            let challenge = parseBearerChallenge(initialHTTPResponse.value(forHTTPHeaderField: "WWW-Authenticate"))
            if let challenge {
                let bearerAuthorization = try await fetchRegistryToken(
                    challenge: challenge,
                    repositoryPath: context.repositoryPath,
                    authentication: authentication
                )
                let retryRequest = makeTagsListRequest(url: url, authorization: bearerAuthorization)
                let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
                    throw ClientRegistryError.storageError("Registry tags retry response was not HTTP")
                }
                if (200..<300).contains(retryHTTPResponse.statusCode) {
                    let decoded = try JSONDecoder().decode(RegistryTagsListResponse.self, from: retryData)
                    return decoded.tags ?? []
                }
            }
        }

        if initialHTTPResponse.statusCode == 404 {
            throw ClientRegistryError.storageError("Registry repository not found")
        }

        throw ClientRegistryError.storageError("Registry tags request failed with status \(initialHTTPResponse.statusCode)")
    }

    func validateCredentials(serverAddress: String, username: String, password: String) async throws -> Bool {
        guard !serverAddress.isEmpty else {
            throw ClientRegistryError.invalidServerAddress
        }

        guard !username.isEmpty, !password.isEmpty else {
            throw ClientRegistryError.invalidCredentials
        }

        do {
            _ = try await testRegistryWithAppleContainer(serverAddress: serverAddress, username: username, password: password)
            return true
        } catch let error as ClientRegistryError {
            throw error
        } catch {
            throw ClientRegistryError.authenticationFailed(String(describing: error))
        }
    }

    private func testRegistryWithAppleContainer(serverAddress: String, username: String, password: String) async throws -> String {
        let auth = BasicAuthentication(username: username, password: password)

        let resolvedServer: String
        let scheme: RequestScheme
        let host: String
        let port: Int?

        if serverAddress.hasPrefix("http://") || serverAddress.hasPrefix("https://") {
            guard let url = URL(string: serverAddress), let urlHost = url.host else {
                throw ClientRegistryError.invalidServerAddress
            }
            resolvedServer = url.host.map(Reference.resolveDomain(domain:)) ?? serverAddress
            host = Reference.resolveDomain(domain: urlHost)
            port = url.port
            scheme = try RequestScheme(url.scheme ?? RequestScheme.auto.rawValue)
        } else {
            resolvedServer = Reference.resolveDomain(domain: serverAddress)
            scheme = try RequestScheme.auto.schemeFor(host: resolvedServer)
            let urlString = "\(scheme.rawValue)://\(resolvedServer)"
            guard let url = URL(string: urlString), let urlHost = url.host else {
                throw ClientRegistryError.invalidServerAddress
            }
            host = urlHost
            port = url.port
        }

        let registryClient = RegistryClient(
            host: host,
            scheme: scheme.rawValue,
            port: port,
            authentication: auth
        )

        try await registryClient.ping()

        // TODO: Revisit this. Understand if socktainer should return a token, or let the
        //       client handle this mechanism
        return ""
    }

    func storeCredentials(serverAddress: String, username: String, password: String, logger: Logger) async throws {
        let normalizedServer = normalizeServerAddress(serverAddress)

        do {
            // Work around apple/container private-registry auth issues by delegating persistence
            // to the Apple CLI instead of maintaining Socktainer-owned keychain items here.
            // Manual intervention may still be required for affected users; see:
            // https://github.com/apple/container/issues/816#issuecomment-3534438608
            // https://github.com/apple/container/issues/816#issuecomment-3503618765
            try runContainerRegistryLogin(serverAddress: normalizedServer, username: username, password: password)
            logger.info("Credentials stored successfully using container registry login for \(normalizedServer)")
        } catch {
            logger.error("Failed to store credentials using container registry login: \(error)")
            throw ClientRegistryError.storageError("Failed to store credentials: \(error.localizedDescription)")
        }
    }

    func retrieveCredentials(serverAddress: String, logger: Logger) async throws -> Authentication? {
        let normalizedServer = normalizeServerAddress(serverAddress)
        logger.debug("Retrieving credentials for registry: \(normalizedServer)")

        let keychainHelper = KeychainHelper(securityDomain: keychainEntryId)

        do {
            let auth = try keychainHelper.lookup(hostname: normalizedServer)
            logger.debug("Credentials found for \(normalizedServer)")
            return auth
        } catch KeychainHelper.Error.keyNotFound {
            logger.debug("No credentials found for \(normalizedServer)")
            return nil
        } catch {
            logger.error("Failed to retrieve credentials from keychain: \(error)")
            throw ClientRegistryError.storageError("Failed to retrieve credentials: \(error.localizedDescription)")
        }
    }

    func login(serverAddress: String, username: String, password: String, logger: Logger) async throws -> String {
        let identityToken: String
        do {
            identityToken = try await testRegistryWithAppleContainer(serverAddress: serverAddress, username: username, password: password)
        } catch let error as ClientRegistryError {
            logger.error("Login failed for \(serverAddress): \(error)")
            throw error
        } catch {
            logger.error("Login failed for \(serverAddress): \(error)")
            throw ClientRegistryError.authenticationFailed(String(describing: error))
        }

        let expectedToken = try await BasicAuthentication(username: username, password: password).token()
        if let existing = try await retrieveCredentials(serverAddress: serverAddress, logger: logger),
            let existingToken = try? await existing.token(),
            existingToken == expectedToken
        {
            // NOTE: For push/pull parity we only need the credential to be usable by
            // the backend. If the same credential is already present in the keychain,
            // skip the Apple CLI login helper entirely. Re-running it can fail with
            // keychain access errors and leave the subsequent image push hanging even
            // though the stored credential is already valid.
            logger.info("Matching registry credential already exists for \(serverAddress); skipping container registry login")
            return identityToken
        }

        do {
            try await storeCredentials(serverAddress: serverAddress, username: username, password: password, logger: logger)
        } catch {
            // NOTE: Apple CLI-backed registry login can fail with keychain access
            // errors even when the required credential is already present in the
            // keychain. If the stored credential we can retrieve matches the
            // supplied username/password, treat the login as effectively
            // completed instead of failing the whole Docker API request.
            guard let existing = try await retrieveCredentials(serverAddress: serverAddress, logger: logger),
                let existingToken = try? await existing.token(),
                existingToken == expectedToken
            else {
                throw error
            }
            logger.warning("Registry credential persistence failed, but matching keychain entry already exists for \(serverAddress); continuing")
        }

        logger.info("Successfully logged in to registry: \(serverAddress)")
        return identityToken
    }

    func listTags(reference: String, credentialsOverride: (username: String, password: String)? = nil, logger: Logger) async throws -> [String] {
        let context = try resolveRegistryReference(reference)

        let authentication: Authentication?
        if let credentialsOverride {
            authentication = BasicAuthentication(username: credentialsOverride.username, password: credentialsOverride.password)
        } else {
            do {
                authentication = try await retrieveCredentials(serverAddress: context.host, logger: logger)
            } catch {
                logger.debug("Falling back to anonymous registry tag listing for \(context.host): \(error)")
                authentication = nil
            }
        }

        let tags = try await executeTagsListRequest(context: context, authentication: authentication)
        return tags.sorted()
    }

    private func runContainerRegistryLogin(serverAddress: String, username: String, password: String) throws {
        guard let containerCLIPath = discoverContainerCLIPath() else {
            throw ClientRegistryError.storageError("Unable to find `container` executable in PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: containerCLIPath)
        process.arguments = [
            "registry", "login",
            "--username", username,
            "--password-stdin",
            serverAddress,
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        if let passwordData = "\(password)\n".data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: passwordData)
        }
        try stdinPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let stdout =
            String(data: try stdoutPipe.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr =
            String(data: try stderrPipe.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw ClientRegistryError.storageError(
                "container registry login failed with exit code \(process.terminationStatus). stdout: \(stdout). stderr: \(stderr)"
            )
        }
    }
}
