import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIO
import TerminalProgress
import Vapor

struct BuildRoute: RouteCollection {
    private static let hiddenDockerDir = ".com.apple.container.dockerfiles"

    let client: ClientContainerProtocol
    let builderClient: ClientBuilderProtocol
    let registryClient: ClientRegistryProtocol

    init(client: ClientContainerProtocol, builderClient: ClientBuilderProtocol, registryClient: ClientRegistryProtocol) {
        self.client = client
        self.builderClient = builderClient
        self.registryClient = registryClient
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/build", use: BuildRoute.handler(client: client, builderClient: builderClient, registryClient: registryClient))

    }

}

private enum BuildQueryDecodingError: LocalizedError {
    case invalidJSONMap(name: String)
    case nonStringValue(name: String, key: String)
    case invalidJSONArray(name: String)
    case unsupportedParameter(name: String)
    case invalidVersion(String)
    case invalidContentType(String)
    case unsupportedOutputType(String)
    case invalidRemoteURL(String)
    case remoteFetchFailed(String)
    case invalidRegistryConfig
    case invalidRegistryCredentials(String)
    case buildKitOnlyParameter(name: String)
    case missingBuildContext

    var errorDescription: String? {
        switch self {
        case .invalidJSONMap(let name):
            return "Invalid \(name): expected a JSON object of string pairs"
        case .nonStringValue(let name, let key):
            return "Invalid \(name): value for '\(key)' must be a string"
        case .invalidJSONArray(let name):
            return "Invalid \(name): expected a JSON array of strings"
        case .unsupportedParameter(let name):
            return "Unsupported build parameter: \(name)"
        case .invalidVersion(let version):
            return "Invalid version: expected '1' or '2', got '\(version)'"
        case .invalidContentType(let contentType):
            return "Invalid Content-Type: expected application/x-tar or application/octet-stream, got '\(contentType)'"
        case .unsupportedOutputType(let outputType):
            return "Unsupported output type: \(outputType)"
        case .invalidRemoteURL(let remote):
            return "Invalid remote context URL: \(remote)"
        case .remoteFetchFailed(let reason):
            return "Failed to fetch remote build context: \(reason)"
        case .invalidRegistryConfig:
            return "Invalid X-Registry-Config header"
        case .invalidRegistryCredentials(let server):
            return "Invalid X-Registry-Config credentials for \(server)"
        case .buildKitOnlyParameter(let name):
            return "Build parameter '\(name)' requires builder version '2'"
        case .missingBuildContext:
            return "Build context must be provided as a tar archive in the request body or via the remote parameter"
        }
    }
}

extension BuildRoute {
    private static func shortImageID(_ imageID: String) -> String {
        let normalized: String
        if imageID.hasPrefix("sha256:") {
            normalized = String(imageID.dropFirst("sha256:".count))
        } else {
            normalized = imageID
        }
        return String(normalized.prefix(12))
    }

    private static func dockerfileSteps(from dockerfileData: Data) -> [String] {
        guard let dockerfile = String(data: dockerfileData, encoding: .utf8) else {
            return []
        }

        var logicalLines: [String] = []
        var current = ""

        for rawLine in dockerfile.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if current.isEmpty, trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let continues = trimmed.hasSuffix("\\")
            let segment = continues ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) : trimmed

            if current.isEmpty {
                current = segment
            } else if !segment.isEmpty {
                current += " " + segment
            }

            if !continues, !current.isEmpty {
                logicalLines.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            logicalLines.append(current)
        }

        return logicalLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
    }

    private static func isNoOpBuildInt(_ value: Int?) -> Bool {
        guard let value else {
            return true
        }
        return value == 0
    }

    private static func isNoOpMemswap(_ value: Int?) -> Bool {
        guard let value else {
            return true
        }
        // Docker commonly treats `0` as unset/default and `-1` as "unlimited".
        // Apple's builder path does not expose swap tuning, so accept these
        // no-op/default placeholders rather than rejecting compatible clients.
        return value == 0 || value == -1
    }

    private static func isDefaultBuildNetworkMode(_ value: String?) -> Bool {
        guard let value else {
            return true
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "default":
            return true
        default:
            return false
        }
    }

    private struct PreparedBuildInputs {
        let dockerfilePath: String
        let imageNames: [String]
        let platforms: [Platform]
    }

    private static func generatedBuildReference() -> String {
        "socktainer-build-temp:\(UUID().uuidString.lowercased())"
    }

    private static func decodeJSONStringMap(_ rawValue: String?, name: String) throws -> [String: String] {
        let jsonObject = try decodeJSONObject(rawValue, name: name)

        var result: [String: String] = [:]
        result.reserveCapacity(jsonObject.count)

        for (key, value) in jsonObject {
            guard let stringValue = value as? String else {
                throw BuildQueryDecodingError.nonStringValue(name: name, key: key)
            }
            result[key] = stringValue
        }

        return result
    }

    private static func decodeBuildArgs(_ rawValue: String?) throws -> [String] {
        let jsonObject = try decodeJSONObject(rawValue, name: "buildargs")

        var result: [String] = []
        result.reserveCapacity(jsonObject.count)

        for (key, value) in jsonObject {
            if value is NSNull {
                // Docker accepts {"ARG": null}; preserve the key as best-effort.
                result.append(key)
                continue
            }
            guard let stringValue = value as? String else {
                throw BuildQueryDecodingError.nonStringValue(name: "buildargs", key: key)
            }
            result.append("\(key)=\(stringValue)")
        }

        return result
    }

    private static func decodeJSONObject(_ rawValue: String?, name: String) throws -> [String: Any] {
        guard let rawValue, !rawValue.isEmpty else {
            return [:]
        }
        guard let data = rawValue.data(using: .utf8),
            let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BuildQueryDecodingError.invalidJSONMap(name: name)
        }
        return jsonObject
    }

    private static func decodeJSONStringArray(_ rawValue: String?, name: String) throws -> [String] {
        guard let rawValue, !rawValue.isEmpty else {
            return []
        }
        guard let data = rawValue.data(using: .utf8),
            let jsonObject = try JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw BuildQueryDecodingError.invalidJSONArray(name: name)
        }

        var result: [String] = []
        result.reserveCapacity(jsonObject.count)
        for value in jsonObject {
            guard let stringValue = value as? String else {
                throw BuildQueryDecodingError.invalidJSONArray(name: name)
            }
            result.append(stringValue)
        }
        return result
    }

    private static func decodeOutputs(_ rawValue: String?) throws -> [Builder.BuildExport]? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }
        guard let data = rawValue.data(using: .utf8),
            let jsonObject = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw BuildQueryDecodingError.invalidJSONArray(name: "outputs")
        }

        var exports: [Builder.BuildExport] = []
        exports.reserveCapacity(jsonObject.count)

        for item in jsonObject {
            guard let type = item["Type"] as? String else {
                throw BuildQueryDecodingError.invalidJSONArray(name: "outputs")
            }
            guard type == "moby" else {
                throw BuildQueryDecodingError.unsupportedOutputType(type)
            }
            guard let attrs = item["Attrs"] as? [String: String] else {
                throw BuildQueryDecodingError.invalidJSONMap(name: "outputs[].Attrs")
            }

            var translatedType = "oci"
            let requestedType = attrs["type"] ?? "image"
            switch requestedType {
            case "image":
                translatedType = "oci"
            case "tar":
                translatedType = "tar"
            case "local":
                translatedType = "local"
            default:
                throw BuildQueryDecodingError.unsupportedOutputType(requestedType)
            }

            var translatedAttrs = attrs.filter { $0.key != "type" }
            let destination = translatedAttrs.removeValue(forKey: "dest").map { URL(fileURLWithPath: $0) }
            let exportString = (["type=\(translatedType)"] + translatedAttrs.map { "\($0.key)=\($0.value)" }).joined(separator: ",")
            let export = Builder.BuildExport(
                type: translatedType,
                destination: destination,
                additionalFields: translatedAttrs,
                rawValue: exportString
            )
            exports.append(export)
        }

        return exports
    }

    private static func validateBuildRequest(_ req: Request, query: ImageBuildQuery) throws {
        if let contentType = req.headers.contentType?.description,
            !contentType.isEmpty,
            contentType != "application/x-tar",
            contentType != "application/octet-stream"
        {
            throw BuildQueryDecodingError.invalidContentType(contentType)
        }

        if let version = query.version, version != "1", version != "2" {
            throw BuildQueryDecodingError.invalidVersion(version)
        }
        if let outputs = query.outputs, !outputs.isEmpty, query.version != "2" {
            throw BuildQueryDecodingError.buildKitOnlyParameter(name: "outputs")
        }

        // BuildKit does not model Docker's classic intermediate-container
        // cleanup knobs separately here, so accept both flags as no-ops.
        if !isNoOpMemswap(query.memswap) {
            throw BuildQueryDecodingError.unsupportedParameter(name: "memswap")
        }
        if !isNoOpBuildInt(query.cpushares) {
            throw BuildQueryDecodingError.unsupportedParameter(name: "cpushares")
        }
        if let cpusetcpus = query.cpusetcpus, !cpusetcpus.isEmpty {
            throw BuildQueryDecodingError.unsupportedParameter(name: "cpusetcpus")
        }
        if !isNoOpBuildInt(query.cpuperiod) {
            throw BuildQueryDecodingError.unsupportedParameter(name: "cpuperiod")
        }
        if !isNoOpBuildInt(query.cpuquota) {
            throw BuildQueryDecodingError.unsupportedParameter(name: "cpuquota")
        }
        if !isNoOpBuildInt(query.shmsize) {
            throw BuildQueryDecodingError.unsupportedParameter(name: "shmsize")
        }
        // NOTE: The Apple build backend used by socktainer does not expose a
        // Docker-compatible hook for injecting build-time extra hosts, build
        // sandbox network modes, or post-build squash behavior through this API.
        // Reject these explicitly instead of implying they are honored.
        if let extraHosts = query.extrahosts, !extraHosts.isEmpty {
            throw BuildQueryDecodingError.unsupportedParameter(name: "extrahosts")
        }
        if !isDefaultBuildNetworkMode(query.networkmode) {
            throw BuildQueryDecodingError.unsupportedParameter(name: "networkmode")
        }
        if let squash = query.squash, squash {
            throw BuildQueryDecodingError.unsupportedParameter(name: "squash")
        }
        if !isNoOpBuildInt(query.memory) {
            throw BuildQueryDecodingError.unsupportedParameter(name: "memory")
        }
        if let platform = query.platform, !platform.isEmpty {
            _ = try Platform(from: platform)
        }
    }

    private static func parseDockerBool(_ rawValue: String?) -> Bool {
        guard let rawValue else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "0", "no", "false", "none":
            return false
        default:
            return true
        }
    }

    private static func decodeRegistryConfigHeader(_ headerValue: String?) throws -> [(server: String, username: String, password: String)] {
        RegistryAuthUtility.decodeRegistryConfigHeader(headerValue).map {
            (server: $0.server, username: $0.username, password: $0.password)
        }
    }

    private static func isGitRemote(_ remote: String) -> Bool {
        remote.hasPrefix("git://")
            || remote.hasSuffix(".git")
            || remote.contains("github.com:")
            || remote.contains("git@")
    }

    private static func isTarballURL(_ url: URL, contentType: String?) -> Bool {
        let path = url.path.lowercased()
        if path.hasSuffix(".tar") || path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") || path.hasSuffix(".tar.bz2")
            || path.hasSuffix(".tbz2") || path.hasSuffix(".tar.xz") || path.hasSuffix(".txz")
        {
            return true
        }
        guard let contentType else {
            return false
        }
        return contentType.contains("application/x-tar")
            || contentType.contains("application/gzip")
            || contentType.contains("application/x-gzip")
            || contentType.contains("application/x-bzip2")
            || contentType.contains("application/x-xz")
    }

    private static func fetchRemoteContext(
        remote: String,
        dockerfile: String,
        into tempContextDir: URL,
        logger: Logger
    ) async throws -> (contextDir: String, dockerfile: String) {
        if isGitRemote(remote) {
            let contextDir = tempContextDir.appendingPathComponent("context")
            try FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "clone", "--depth=1", remote, contextDir.path]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw BuildQueryDecodingError.remoteFetchFailed(stderr.isEmpty ? "git clone failed" : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (contextDir.path, dockerfile)
        }

        guard let remoteURL = URL(string: remote),
            let scheme = remoteURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw BuildQueryDecodingError.invalidRemoteURL(remote)
        }

        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BuildQueryDecodingError.remoteFetchFailed("unexpected HTTP response")
        }

        if isTarballURL(remoteURL, contentType: http.value(forHTTPHeaderField: "Content-Type")?.lowercased()) {
            let tarPath = tempContextDir.appendingPathComponent("remote-context.tar")
            try data.write(to: tarPath, options: .atomic)
            let extractDir = tempContextDir.appendingPathComponent("context")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            logger.info("Extracting remote tar build context from \(remoteURL.absoluteString)")
            try ArchiveUtility.extractBuildContext(tarPath: tarPath, to: extractDir, logger: logger)
            return (extractDir.path, dockerfile)
        }

        let extractDir = tempContextDir.appendingPathComponent("context")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let dockerfileURL = extractDir.appendingPathComponent("Dockerfile")
        try data.write(to: dockerfileURL, options: .atomic)
        return (extractDir.path, "Dockerfile")
    }

    private static func prepareBuildInputs(
        dockerfile: String,
        contextDir: String,
        targetImageNames: [String],
        platform: String
    ) throws -> PreparedBuildInputs {
        let dockerfilePath = URL(fileURLWithPath: contextDir).appendingPathComponent(dockerfile).path
        guard let _ = try? FileIOUtility.readData(at: URL(filePath: dockerfilePath)) else {
            throw ContainerizationError(.invalidArgument, message: "Dockerfile does not exist at path: \(dockerfilePath)")
        }

        let imageNames: [String] = try targetImageNames.map { targetImageName in
            let parsedReference = try Reference.parse(targetImageName)
            parsedReference.normalize()
            return parsedReference.description
        }

        let platforms: [Platform]
        if platform.isEmpty {
            platforms = [try Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")]
        } else {
            platforms = [try Platform(from: platform)]
        }

        return PreparedBuildInputs(
            dockerfilePath: dockerfilePath,
            imageNames: imageNames,
            platforms: platforms
        )
    }

    static func handler(client: ClientContainerProtocol, builderClient: ClientBuilderProtocol, registryClient: ClientRegistryProtocol)
        -> @Sendable (Request) async throws -> Response
    {
        { req in
            var query = try req.query.decode(ImageBuildQuery.self)

            // Apply Docker API defaults if not provided
            if query.dockerfile == nil { query.dockerfile = "Dockerfile" }
            if query.q == nil { query.q = false }
            if query.nocache == nil { query.nocache = false }
            if query.rm == nil { query.rm = true }
            if query.forcerm == nil { query.forcerm = false }
            if query.platform == nil { query.platform = "" }
            if query.target == nil { query.target = "" }
            if query.outputs == nil { query.outputs = "" }
            if query.version == nil { query.version = "1" }
            do {
                try validateBuildRequest(req, query: query)
            } catch {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }

            do {
                _ = try decodeRegistryConfigHeader(req.headers.first(name: "X-Registry-Config"))
            } catch {
                throw Abort(.badRequest, reason: error.localizedDescription)
            }

            // Extract values with Docker-compliant defaults
            let requestedDockerfile = query.dockerfile ?? "Dockerfile"
            let requestedTags = (query.t.map { [$0] } ?? []).filter { !$0.isEmpty }
            let requestedImageNames = requestedTags
            let targetImageNames = requestedImageNames.isEmpty ? [generatedBuildReference()] : requestedImageNames
            let quiet = query.q ?? false
            let noCache = query.nocache ?? false
            let pull = parseDockerBool(query.pull)
            let target = query.target ?? ""
            let platform = query.platform ?? ""
            // NOTE: The route accepts Docker API versions "1" and "2" for wire
            // compatibility, but both code paths run through the same Apple
            // BuildKit-backed builder service. Exact classic-builder v1 semantics
            // are not available through the backend socktainer uses here.

            do {
                try await builderClient.ensureReachable(
                    timeout: .seconds(3),
                    retryInterval: .milliseconds(250),
                    logger: req.logger
                )
            } catch {
                throw Abort(.internalServerError, reason: "BuildKit builder is not running or reachable: \(error.localizedDescription)")
            }

            // Extract tar archive from request body and unpack to temporary directory
            let contextDir: String
            let dockerfile: String
            let buildUUID = UUID().uuidString
            let appSupportDir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("com.apple.container/builder")
            let tempContextDir = appSupportDir.appendingPathComponent(buildUUID)

            do {
                // Create temporary directory for build context
                try FileManager.default.createDirectory(at: tempContextDir, withIntermediateDirectories: true, attributes: nil)

                if let remote = query.remote, !remote.isEmpty {
                    let remoteContext = try await fetchRemoteContext(
                        remote: remote,
                        dockerfile: requestedDockerfile,
                        into: tempContextDir,
                        logger: req.logger
                    )
                    contextDir = remoteContext.contextDir
                    dockerfile = remoteContext.dockerfile
                } else {
                    req.logger.info("Build context upload detected; preparing to read request body")

                    // Write the body data to a temporary tar file using streaming
                    let tarPath = tempContextDir.appendingPathComponent("context.tar")
                    var fileHandle: FileHandle?
                    var totalBytesWritten = 0

                    do {
                        // Create the tar file and open file handle for writing
                        FileManager.default.createFile(atPath: tarPath.path, contents: nil)
                        fileHandle = try FileHandle(forWritingTo: tarPath)

                        // Stream the body directly to the tar file without loading into memory
                        if let bodyData = req.body.data {
                            // Direct body data available
                            let data = Data(buffer: bodyData)
                            try fileHandle?.write(contentsOf: data)
                            totalBytesWritten = data.count
                            req.logger.info("Build context body received as buffered data (\(data.count) bytes)")
                        } else {
                            var chunkCount = 0
                            req.logger.info("Build context body will be streamed in chunks")
                            for try await var chunk in req.body {
                                guard let data = chunk.readData(length: chunk.readableBytes) else {
                                    continue
                                }
                                chunkCount += 1
                                try fileHandle?.write(contentsOf: data)
                                totalBytesWritten += data.count
                            }
                            req.logger.info("Finished reading build context body (\(chunkCount) chunks, \(totalBytesWritten) bytes)")
                        }

                        try fileHandle?.synchronize()
                        try fileHandle?.close()
                        fileHandle = nil
                        req.logger.info("Build context tarball written to \(tarPath.path)")
                    } catch {
                        // Clean up file handle and partial tar file on error
                        try? fileHandle?.close()
                        try? FileManager.default.removeItem(at: tarPath)
                        req.logger.error("Failed to stream body to tar file: \(error)")
                        throw Abort(.badRequest, reason: "Failed to process request body: \(error.localizedDescription)")
                    }

                    guard totalBytesWritten > 0 else {
                        req.logger.warning("No data received in request body")
                        throw Abort(.badRequest, reason: BuildQueryDecodingError.missingBuildContext.localizedDescription)
                    }
                    guard FileManager.default.fileExists(atPath: tarPath.path),
                        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: tarPath.path),
                        let fileSize = fileAttributes[.size] as? Int64,
                        fileSize > 0
                    else {
                        req.logger.error("Tar file is missing or empty after writing \(totalBytesWritten) bytes")
                        throw Abort(.badRequest, reason: "Failed to write tar archive to disk")
                    }
                    // Extract the tar archive
                    let extractDir = tempContextDir.appendingPathComponent("context")
                    try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true, attributes: nil)

                    do {
                        req.logger.info("Starting build context extraction from \(tarPath.path) to \(extractDir.path)")
                        try ArchiveUtility.extractBuildContext(tarPath: tarPath, to: extractDir, logger: req.logger)
                        req.logger.info("Finished build context extraction to \(extractDir.path)")
                    } catch {
                        req.logger.error("Tar extraction failed: \(String(describing: error))")

                        throw Abort(.badRequest, reason: "Failed to extract tar archive: \(error.localizedDescription)")
                    }
                    contextDir = extractDir.path
                    dockerfile = requestedDockerfile
                }
            } catch {
                // Clean up on error
                try? FileManager.default.removeItem(at: tempContextDir)
                throw error
            }

            let buildArgs = try decodeBuildArgs(query.buildargs).sorted()

            let labels = try decodeJSONStringMap(query.labels, name: "labels")
                .map { "\($0.key)=\($0.value)" }
                .sorted()

            let cacheFrom = try decodeJSONStringArray(query.cachefrom, name: "cachefrom")
            let requestedOutputs = try decodeOutputs(query.outputs)
            let preparedBuildInputs: PreparedBuildInputs
            do {
                preparedBuildInputs = try prepareBuildInputs(
                    dockerfile: dockerfile,
                    contextDir: contextDir,
                    targetImageNames: targetImageNames,
                    platform: platform
                )
            } catch {
                if contextDir != "." {
                    try? FileManager.default.removeItem(at: tempContextDir)
                }
                let reason = error is ContainerizationError ? "\(error)" : error.localizedDescription
                throw Abort(.badRequest, reason: reason)
            }

            // Create streaming response for build output
            req.logger.info("Build context ready at \(contextDir); handing off to build execution")
            let body = Response.Body { writer in
                Swift.Task.detached {
                    do {
                        try await BuildRoute.performBuild(
                            dockerfile: dockerfile,
                            contextDir: contextDir,
                            requestedTargetImageNames: requestedImageNames,
                            targetImageNames: preparedBuildInputs.imageNames,
                            buildArgs: buildArgs,
                            labels: labels,
                            cacheFrom: cacheFrom,
                            noCache: noCache,
                            pull: pull,
                            target: target,
                            platforms: preparedBuildInputs.platforms,
                            quiet: quiet,
                            requestedOutputs: requestedOutputs,
                            builderClient: builderClient,
                            writer: writer,
                            logger: req.logger
                        )

                        // Clean up temporary context directory if it was created
                        if contextDir != "." {
                            try? FileManager.default.removeItem(at: tempContextDir)
                        }
                    } catch {
                        req.logger.error("Build failed: \(error)")

                        // Extract error message - prioritize ContainerizationError message
                        let errorMessage: String
                        if error is ContainerizationError {
                            // Use string interpolation to get ContainerizationError's description
                            errorMessage = "\(error)"
                        } else {
                            errorMessage = error.localizedDescription
                        }

                        // Docker API compliant error response
                        let errorDetail: [String: Any] = [
                            "message": errorMessage
                        ]

                        let errorResponse: [String: Any] = [
                            "errorDetail": errorDetail,
                            "error": errorMessage,
                        ]

                        if let jsonData = try? JSONSerialization.data(withJSONObject: errorResponse),
                            let jsonString = String(data: jsonData, encoding: .utf8)
                        {
                            _ = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))
                        } else {
                            let fallbackError = """
                                {"errorDetail":{"message":"Build failed"},"error":"Build failed"}

                                """
                            _ = writer.write(.buffer(ByteBuffer(string: fallbackError)))
                        }

                        // Clean up temporary context directory on error
                        if contextDir != "." {
                            try? FileManager.default.removeItem(at: tempContextDir)
                        }
                        _ = writer.write(.end)
                    }
                }
            }

            return Response(
                status: .ok,
                headers: [
                    "Content-Type": "application/json",
                    "Transfer-Encoding": "chunked",
                ],
                body: body
            )
        }
    }

    private static func performBuild(
        dockerfile: String,
        contextDir: String,
        requestedTargetImageNames: [String],
        targetImageNames: [String],
        buildArgs: [String],
        labels: [String],
        cacheFrom: [String],
        noCache: Bool,
        pull: Bool,
        target: String,
        platforms: [Platform],
        quiet: Bool,
        requestedOutputs: [Builder.BuildExport]?,
        builderClient: ClientBuilderProtocol,
        writer: BodyStreamWriter,
        logger: Logger
    ) async throws {

        // NOTE: This route targets the classic non-BuildKit Docker build flow,
        // not `docker buildx build` / BuildKit client UX. Apple container's
        // builder emits a different progress model than classic Docker.
        // This route intentionally sticks to legacy Docker-style `stream` frames.
        // The current `docker build` legacy CLI path treats every aux payload as
        // a `build.Result`, so emitting BuildKit-style `moby.buildkit.trace`
        // records here would surface parse errors instead of pretty progress.
        // We therefore translate Apple's plain build output into best-effort
        // classic Docker text rather than emitting BuildKit aux events.
        // Helper function to send Docker API compliant streaming messages
        @Sendable func sendStreamRecord(_ message: String) {
            guard !quiet else {
                return
            }
            let streamResponse: [String: Any] = ["stream": message]
            if let jsonData = try? JSONSerialization.data(withJSONObject: streamResponse),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                let result = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))

                // Log write failures for debugging but don't crash
                result.whenFailure { error in
                    logger.debug("BuildRoute: Write failed - \(error)")
                }
            }
        }

        @Sendable func sendStreamMessage(_ message: String) {
            sendStreamRecord(message + "\n")
        }

        final class BuildOutputTranslator {
            private let dockerfileSteps: [String]
            private let initialDockerfileStepOffset: Int
            private var pending = ""
            private var lastEmittedStepNumber: Int?
            private var emittedStepNumbers: Set<Int> = []

            init(dockerfileSteps: [String]) {
                self.dockerfileSteps = dockerfileSteps
                self.initialDockerfileStepOffset =
                    dockerfileSteps.first.map { $0.uppercased().hasPrefix("FROM ") } == true ? 1 : 0
                if initialDockerfileStepOffset == 1 {
                    emittedStepNumbers.insert(1)
                    lastEmittedStepNumber = 1
                }
            }

            func ingest(_ chunk: String) -> [String] {
                pending += chunk
                var results: [String] = []

                while let newline = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if let translated = translateLine(line) {
                        results.append(translated)
                    }
                }

                return results
            }

            func finish() -> [String] {
                var results: [String] = []

                if !pending.isEmpty {
                    defer { pending.removeAll(keepingCapacity: false) }
                    if let translated = translateLine(pending) {
                        results.append(translated)
                    }
                }

                // Apple/BuildKit sometimes omits metadata-only cached steps
                // (for example WORKDIR) from the plain progress stream. Docker's
                // legacy builder still prints those steps, so emit any trailing
                // unreported Dockerfile instructions here as a best-effort
                // compatibility fallback.
                if !dockerfileSteps.isEmpty {
                    let start = (lastEmittedStepNumber ?? 0) + 1
                    if start <= dockerfileSteps.count {
                        for stepNumber in start...dockerfileSteps.count where !emittedStepNumbers.contains(stepNumber) {
                            results.append("Step \(stepNumber)/\(dockerfileSteps.count) : \(dockerfileSteps[stepNumber - 1])\n")
                            results.append(" ---> Using cache\n")
                            emittedStepNumbers.insert(stepNumber)
                        }
                    }
                }

                return results
            }

            private func translateLine(_ rawLine: String) -> String? {
                let line = rawLine.trimmingCharacters(in: .newlines)
                guard !line.isEmpty else {
                    return nil
                }

                guard line.hasPrefix("#") else {
                    return line + "\n"
                }

                let remainder = line.dropFirst()
                let stepID = remainder.prefix { $0.isNumber }
                guard !stepID.isEmpty else {
                    return nil
                }

                var rest = remainder.dropFirst(stepID.count)
                guard rest.first == " " else {
                    return nil
                }
                rest = rest.dropFirst()

                if rest == "CACHED" {
                    return " ---> Using cache\n"
                }

                if rest.hasPrefix("DONE") {
                    return nil
                }

                if rest.first == "[" {
                    guard let closingBracket = rest.firstIndex(of: "]") else {
                        return nil
                    }
                    let bracketContent = String(rest[rest.index(after: rest.startIndex)..<closingBracket])

                    if let stepRange = bracketContent.split(separator: " ").last,
                        let slash = stepRange.firstIndex(of: "/")
                    {
                        let current = stepRange[..<slash]
                        let total = stepRange[stepRange.index(after: slash)...]
                        if !current.isEmpty, !total.isEmpty,
                            current.allSatisfy(\.isNumber), total.allSatisfy(\.isNumber),
                            let currentStep = Int(current)
                        {
                            let dockerfileStepNumber = currentStep + initialDockerfileStepOffset
                            guard dockerfileStepNumber >= 1, dockerfileStepNumber <= dockerfileSteps.count else {
                                return nil
                            }
                            defer {
                                lastEmittedStepNumber = dockerfileStepNumber
                                emittedStepNumbers.insert(dockerfileStepNumber)
                            }
                            guard lastEmittedStepNumber != dockerfileStepNumber else {
                                return nil
                            }
                            return "Step \(dockerfileStepNumber)/\(dockerfileSteps.count) : \(dockerfileSteps[dockerfileStepNumber - 1])\n"
                        }
                    }

                    let suppressedBracketPrefixes = ["resolver", "internal", "auth", "load metadata", "exporting"]
                    if suppressedBracketPrefixes.contains(where: { bracketContent.hasPrefix($0) }) {
                        return nil
                    }

                    return nil
                }

                if let firstSpace = rest.firstIndex(of: " ") {
                    let maybeTime = rest[..<firstSpace]
                    if maybeTime.contains("."), maybeTime.allSatisfy({ $0.isNumber || $0 == "." }) {
                        let payload = rest[rest.index(after: firstSpace)...]
                        return String(payload) + "\n"
                    }
                }

                let stringRest = String(rest)
                let suppressedPrefixes = [
                    "transferring ",
                    "resolve ",
                    "extracting ",
                    "exporting ",
                    "sending tarball",
                    "fetching image...",
                    "oci-layout://",
                    "sha256:",
                ]
                if suppressedPrefixes.contains(where: { stringRest.hasPrefix($0) }) {
                    return nil
                }

                return stringRest + "\n"
            }
        }

        func streamCapturedBuildOutput(
            from fileHandle: FileHandle,
            dockerfileSteps: [String],
            writer: BodyStreamWriter,
            logger: Logger
        ) -> Swift.Task<Void, Never> {
            Swift.Task.detached {
                let translator = BuildOutputTranslator(dockerfileSteps: dockerfileSteps)
                @Sendable func writeJSONObject(
                    _ object: [String: Any],
                    failureContext: String
                ) {
                    guard let jsonData = try? JSONSerialization.data(withJSONObject: object),
                        let jsonString = String(data: jsonData, encoding: .utf8)
                    else {
                        return
                    }

                    let result = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))
                    result.whenFailure { error in
                        logger.debug("BuildRoute: \(failureContext) - \(error)")
                    }
                }

                @Sendable func emitTranslatedLines(_ lines: [String]) {
                    for translatedLine in lines {
                        writeJSONObject(
                            ["stream": translatedLine],
                            failureContext: "Captured IO write failed"
                        )
                    }
                }

                while !Swift.Task.isCancelled {
                    let data = fileHandle.availableData
                    guard !data.isEmpty else {
                        break
                    }
                    if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                        emitTranslatedLines(translator.ingest(chunk))
                    }
                }

                emitTranslatedLines(translator.finish())
            }
        }

        @Sendable func sendAuxMessage(imageID: String) {
            let response: [String: Any] = [
                "aux": [
                    "ID": imageID
                ]
            ]

            if let jsonData = try? JSONSerialization.data(withJSONObject: response),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                let result = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))
                result.whenFailure { error in
                    logger.debug("BuildRoute: Aux message write failed - \(error)")
                }
            }
        }

        func sendProgressMessage(id: String, status: String, progressDetail: [String: Any]? = nil) {
            guard !quiet else {
                return
            }
            var response: [String: Any] = [
                "id": id,
                "status": status,
            ]
            if let detail = progressDetail {
                response["progressDetail"] = detail
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: response),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                let result = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))
                result.whenFailure { error in
                    logger.debug("BuildRoute: Progress message write failed - \(error)")
                }
            }
        }

        let timeout: Duration = .seconds(300)

        let builder = try await builderClient.connect(
            timeout: timeout,
            retryInterval: .seconds(1),
            logger: logger
        )

        // resolve the full path to the Dockerfile
        let dockerfilePath = URL(fileURLWithPath: contextDir).appendingPathComponent(dockerfile).path
        logger.info("Reading Dockerfile at path: \(dockerfilePath)")

        guard let dockerfileData = try? FileIOUtility.readData(at: URL(filePath: dockerfilePath)) else {
            throw ContainerizationError(.invalidArgument, message: "Dockerfile does not exist at path: \(dockerfilePath)")
        }

        let dockerfileSteps = dockerfileSteps(from: dockerfileData)
        if !quiet {
            if dockerfileSteps.isEmpty {
                sendStreamRecord("Step 1/1 : Starting build for \(targetImageNames.first ?? "build")")
                sendStreamRecord("\n")
            } else if dockerfileSteps.first?.uppercased().hasPrefix("FROM ") == true {
                sendStreamRecord("Step 1/\(dockerfileSteps.count) : \(dockerfileSteps[0])")
                sendStreamRecord("\n")
            }
        }

        let dockerignorePath = dockerfilePath + ".dockerignore"
        let dockerignoreURL = URL(filePath: dockerignorePath)
        let dockerignoreData = try? FileIOUtility.readData(at: dockerignoreURL)

        let outputPipe = quiet ? nil : Pipe()
        let outputHandle = outputPipe?.fileHandleForWriting
        let capturedOutputTask = outputPipe.map {
            streamCapturedBuildOutput(from: $0.fileHandleForReading, dockerfileSteps: dockerfileSteps, writer: writer, logger: logger)
        }

        // Setup temp directory - must use the builder export path that's mounted in buildkit container
        let builderExportPath = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("com.apple.container/builder")
        let buildID = UUID().uuidString
        let tempURL = builderExportPath.appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)

        let imageNames = targetImageNames

        let exports: [Builder.BuildExport] = try {
            let baseExports = try requestedOutputs ?? [Builder.BuildExport(from: "type=oci")]
            return baseExports.enumerated().map { index, export in
                var exp = export
                if exp.destination == nil {
                    let useLegacyDefaultName = requestedOutputs == nil && baseExports.count == 1
                    switch exp.type {
                    case "local":
                        exp.destination = tempURL.appendingPathComponent(useLegacyDefaultName ? "local" : "local-\(index)")
                    case "tar", "oci":
                        exp.destination = tempURL.appendingPathComponent(useLegacyDefaultName ? "out.tar" : "out-\(index).tar")
                    default:
                        exp.destination = tempURL.appendingPathComponent(useLegacyDefaultName ? "out.tar" : "out-\(index).tar")
                    }
                }
                return exp
            }
        }()

        func makeBuildConfig(pull: Bool) -> ContainerBuild.Builder.BuildConfig {
            ContainerBuild.Builder.BuildConfig(
                buildID: buildID,
                contentStore: RemoteContentStoreClient(),
                buildArgs: buildArgs,
                // TODO: Implement secrets once integration with buildkit materializes
                secrets: [:],
                contextDir: contextDir,
                dockerfile: dockerfileData,
                dockerignore: dockerignoreData,
                labels: labels,
                noCache: noCache,
                platforms: platforms,
                terminal: nil,
                outputHandle: outputHandle,
                progressMode: .plain,
                tags: imageNames,
                target: target,
                quiet: quiet,
                exports: exports,
                cacheIn: cacheFrom,
                cacheOut: [],
                pull: pull
            )
        }

        func shouldRetryWithPull(for error: any Error) -> Bool {
            guard !pull, !platforms.isEmpty else {
                return false
            }

            // Apple build resolution only retries missing refs natively. When a
            // local reference exists but lacks the requested platform variant,
            // the native resolver fails with `unsupported: "platform ..."` until
            // the ref is pulled for that platform. Retry once through Apple's own
            // `pull=true` path so explicit-platform Docker builds recover without
            // inventing custom image-resolution logic in socktainer.
            let message = String(describing: error)
            return message.contains("unsupported: \"platform ")
        }

        do {
            try await builder.build(makeBuildConfig(pull: pull))
        } catch {
            guard shouldRetryWithPull(for: error) else {
                throw error
            }
            logger.info("Retrying build with native pull enabled after platform resolution failure")
            try await builder.build(makeBuildConfig(pull: true))
        }
        var builtImageID: String? = nil
        var exportedDestination: URL? = nil
        let ephemeralBuildReference = requestedTargetImageNames.isEmpty ? targetImageNames.first : nil

        for export in exports {
            switch export.type {
            case "oci":
                guard let destination = export.destination else {
                    throw ContainerizationError(.invalidArgument, message: "dest is required for \(export.rawValue)")
                }
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    logger.error("OCI output image not found at expected path: \(destination.path)")
                    throw ContainerizationError(.unknown, message: "Build completed but no output image found at \(destination.path)")
                }

                let loaded = try await ClientImage.load(from: destination.absolutePath())
                guard loaded.rejectedMembers.isEmpty else {
                    logger.error("Built image archive contains invalid members: \(loaded.rejectedMembers)")
                    throw ContainerizationError(.internalError, message: "failed to load built image archive")
                }

                for image in loaded.images {
                    try await image.unpack(platform: nil, progressUpdate: { _ in })
                }

                if builtImageID == nil {
                    builtImageID = loaded.images.first.map(\.description.digest)
                }

                if let ephemeralBuildReference {
                    try? await ClientImage.delete(reference: ephemeralBuildReference, garbageCollect: false)
                }
            case "tar":
                guard let destination = export.destination else {
                    throw ContainerizationError(.invalidArgument, message: "dest is required for \(export.rawValue)")
                }
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    logger.error("Tar export not found at expected path: \(destination.path)")
                    throw ContainerizationError(.unknown, message: "Build completed but no tar export found at \(destination.path)")
                }
                exportedDestination = destination
            case "local":
                guard let destination = export.destination else {
                    throw ContainerizationError(.invalidArgument, message: "dest is required for \(export.rawValue)")
                }
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    logger.error("Local export not found at expected path: \(destination.path)")
                    throw ContainerizationError(.unknown, message: "Build completed but no local export found at \(destination.path)")
                }
                exportedDestination = destination
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid exporter \(export.rawValue)")
            }
        }

        try? outputPipe?.fileHandleForWriting.close()
        _ = await capturedOutputTask?.value
        try? outputPipe?.fileHandleForReading.close()

        if let builtImageID {
            sendAuxMessage(imageID: builtImageID)
            let shortBuiltImageID = shortImageID(builtImageID)

            if quiet {
                let quietResponse: [String: Any] = ["stream": shortBuiltImageID + "\n"]
                if let jsonData = try? JSONSerialization.data(withJSONObject: quietResponse),
                    let jsonString = String(data: jsonData, encoding: .utf8)
                {
                    _ = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))
                }
            } else {
                sendStreamMessage("Successfully built \(shortBuiltImageID)")
                for tag in imageNames {
                    sendStreamMessage("Successfully tagged \(tag)")
                }
            }
        } else if !quiet, let exportedDestination {
            sendStreamMessage("Successfully exported to \(exportedDestination.path)")
        }

        _ = writer.write(.end)
    }
}
