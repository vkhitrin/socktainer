import ContainerAPIClient
import ContainerNetworkService
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Vapor

struct ContainerCreateRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/create", use: ContainerCreateRoute.handler(client: client))
    }

}
extension ContainerCreateRoute {
    private static let anonymousVolumeLabel = "com.docker.volume.anonymous"

    private static func generatedContainerID() -> String {
        // Apple accepts a caller-provided container identifier. Use an opaque
        // Docker-style hex ID here instead of deriving it from the requested
        // container name so ID-bearing APIs (create/prune/events/inspect) do not
        // leak the user-visible name as the container identifier.
        let first = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let second = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return first + second
    }

    private static func sanitizedCreateRequestBody(_ rawBody: Data) throws -> Data {
        guard
            var jsonObject = try JSONSerialization.jsonObject(with: rawBody) as? [String: Any],
            var hostConfig = jsonObject["HostConfig"] as? [String: Any]
        else {
            return rawBody
        }

        // Apple containers do not implement Docker host-level runtime tuning, so
        // strip those request fields and let create proceed with backend defaults.
        let ignoredHostConfigKeys = [
            "BlkioWeight", "BlkioWeightDevice", "BlkioDeviceReadBps", "BlkioDeviceWriteBps",
            "BlkioDeviceReadIOps", "BlkioDeviceWriteIOps", "MemorySwappiness", "NanoCpus",
            "CpuPeriod", "CpuRealtimePeriod", "CpuRealtimeRuntime", "CpuShares", "CpuQuota",
            "CpusetCpus", "CpusetMems", "Memory", "MemorySwap", "MemoryReservation",
            "KernelMemoryTCP", "OomKillDisable", "OomScoreAdj", "CpuCount", "CpuPercent",
            "IOMaximumIOps", "IOMaximumBandwidth", "ShmSize", "PidsLimit", "CapAdd",
            "CapDrop", "GroupAdd", "Devices", "DeviceCgroupRules", "DeviceRequests",
            "ExtraHosts", "Links", "VolumesFrom", "Tmpfs", "ContainerIDFile", "IpcMode",
            "Cgroup", "Init", "PidMode", "Isolation", "SecurityOpt", "StorageOpt",
            "CgroupParent", "VolumeDriver", "Runtime", "UTSMode", "UsernsMode",
            "Sysctls", "CgroupnsMode", "LogConfig",
        ]
        for key in ignoredHostConfigKeys {
            hostConfig.removeValue(forKey: key)
        }

        if var annotations = hostConfig["Annotations"] as? [String: Any] {
            // Apple containers do not support Docker's PortSpecs annotation.
            annotations.removeValue(forKey: "PortSpecs")
            hostConfig["Annotations"] = annotations
        }

        jsonObject["HostConfig"] = hostConfig

        return try JSONSerialization.data(withJSONObject: jsonObject)
    }

    private static func attachmentOptions(hostname: String, macAddress: MACAddress?) -> AttachmentOptions {
        AttachmentOptions(hostname: hostname, macAddress: macAddress)
    }

    private static func validatedEndpointMacAddress(
        _ endpoint: EndpointSettings,
        fallback requestedMacAddress: MACAddress?
    ) throws -> MACAddress? {
        if let endpointMac = endpoint.macAddress, !endpointMac.isEmpty {
            try Utility.validMACAddress(endpointMac)
            return try MACAddress(endpointMac)
        }

        // Apple containers do not expose Docker endpoint-level networking knobs
        // beyond a requested MAC address, so ignore the rest of NetworkingConfig.
        return requestedMacAddress
    }

    private static func validateNameservers(_ nameservers: [String]) throws {
        for nameserver in nameservers {
            let isValidIPv4 = (try? IPv4Address(nameserver)) != nil
            let isValidIPv6 = (try? IPv6Address(nameserver)) != nil
            guard isValidIPv4 || isValidIPv6 else {
                throw Abort(.badRequest, reason: "nameserver '\(nameserver)' is not a valid IPv4 or IPv6 address")
            }
        }
    }

    private static func underlyingContainerizationError(_ error: any Error) -> ContainerizationError? {
        guard let error = error as? ContainerizationError else {
            return nil
        }
        if error.code != .internalError {
            return error
        }
        if let cause = error.cause {
            return underlyingContainerizationError(cause) ?? error
        }
        return error
    }

    private static func abortForCreateError(_ error: any Error) -> Abort {
        if let abort = error as? Abort {
            return abort
        }
        if let abort = error as? AbortError {
            return Abort(abort.status, reason: abort.reason)
        }

        if let error = underlyingContainerizationError(error) {
            switch error.code {
            case .invalidArgument:
                return Abort(.badRequest, reason: error.message)
            case .notFound:
                return Abort(.notFound, reason: error.message)
            case .exists:
                return Abort(.conflict, reason: error.message)
            default:
                return Abort(.internalServerError, reason: "Failed to create container: \(error)")
            }
        }

        return Abort(.internalServerError, reason: "Failed to create container: \(error)")
    }

    private static func handleCreateRequest(
        _ req: Request,
        client: ClientContainerProtocol
    ) async throws -> Response {
        let query = try req.query.decode(ContainerCreateQuery.self)

        let containerName = query.name
        let containerPlatform = query.platform.flatMap { $0.isEmpty ? nil : $0 } ?? "linux/\(Arch.hostArchitecture().rawValue)"

        guard let bodyData = try await req.body.collect().get() else {
            throw Abort(.badRequest, reason: "Missing request body")
        }
        guard let rawBody = bodyData.getData(at: 0, length: bodyData.readableBytes) else {
            throw Abort(.badRequest, reason: "Failed to read request body")
        }
        let sanitizedBody = try sanitizedCreateRequestBody(rawBody)
        let body = try JSONDecoder().decode(ContainerCreateRequest.self, from: sanitizedBody)

        req.logger.info("Creating container for image: \(body.image ?? "")")

        let id = generatedContainerID()
        try Utility.validEntityName(id)

        // Validate the requested platform only if provided
        let requestedPlatform = try Platform(from: containerPlatform)

        // Check if image exists locally
        do {
            _ = try await ClientImage.get(reference: body.image ?? "")
        } catch {
            throw Abort(.notFound, reason: "No such image: \(body.image ?? "")")
        }

        let img = try await ClientImage.fetch(
            reference: body.image ?? "",
            platform: requestedPlatform,
        )

        // Unpack a fetched image before use
        try await img.getCreateSnapshot(
            platform: requestedPlatform
        )

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        let initImage = try await ClientImage.fetch(
            reference: ClientImage.initImageRef, platform: .current
        )

        _ = try await initImage.getCreateSnapshot(
            platform: .current)

        let imageConfig = try await img.config(for: requestedPlatform).config

        let defaultUser: ProcessConfiguration.User = {
            if let u = imageConfig?.user {
                return .raw(userString: u)
            }
            return .id(uid: 0, gid: 0)
        }()

        let workingDirectory = imageConfig?.workingDir ?? "/"

        let imageConfigEnvironment = imageConfig?.env ?? []
        let requestedEnvironment = body.env ?? []
        // merge environment variables, with request taking precedence
        let mergedEnv = try Parser.allEnv(imageEnvs: imageConfigEnvironment, envFiles: [], envs: requestedEnvironment)

        let publishedPorts: [PublishPort]
        do {
            let portBindings = (body.hostConfig?.portBindings ?? [:]).mapValues { $0 ?? [] }
            publishedPorts = try convertPortBindings(
                from: portBindings
            )
        } catch {
            if let abort = error as? AbortError {
                throw Abort(abort.status, reason: abort.reason)
            }
            req.logger.error("Failed to allocate ports: \(error)")
            throw Abort(.internalServerError, reason: "Failed to allocate ports: \(error)")
        }

        // Handle Entrypoint and Cmd from request, following Docker semantics
        var commandLine: [String] = []

        // Determine the entrypoint to use
        let entrypoint: [String]
        if let requestEntrypoint = body.entrypoint {
            // If entrypoint is explicitly provided (even if empty), use it
            entrypoint = requestEntrypoint
        } else if let imageEntrypoint = imageConfig?.entrypoint {
            // Otherwise use image's entrypoint
            entrypoint = imageEntrypoint
        } else {
            // No entrypoint specified
            entrypoint = []
        }

        // Determine the command to use
        let command: [String]
        if let requestCmd = body.cmd {
            // If cmd is explicitly provided but empty, use image's cmd
            command = requestCmd.isEmpty ? (imageConfig?.cmd ?? []) : requestCmd
        } else if body.entrypoint != nil {
            // If entrypoint was explicitly overridden, don't use image's cmd
            command = []
        } else {
            // Use image's cmd
            command = imageConfig?.cmd ?? []
        }

        // Build final command line
        commandLine.append(contentsOf: entrypoint)
        commandLine.append(contentsOf: command)

        // Use working directory from request if provided and not empty, otherwise from image config
        let finalWorkingDirectory = body.workingDir.flatMap { $0.isEmpty ? nil : $0 } ?? workingDirectory

        // Handle user from request if provided
        let finalUser: ProcessConfiguration.User = {
            if let requestUser = body.user {
                return .raw(userString: requestUser)
            }
            return defaultUser
        }()

        // Ensure we have a valid executable
        guard let executable = commandLine.first, !executable.isEmpty else {
            req.logger.error("No executable specified for container")
            throw Abort(.badRequest, reason: "No executable specified for container. Image must specify ENTRYPOINT or CMD, or request must provide Entrypoint or Cmd.")
        }

        let processConfig = ProcessConfiguration(
            executable: executable,
            arguments: commandLine.dropFirst().map { String($0) },
            environment: mergedEnv,
            workingDirectory: finalWorkingDirectory,
            terminal: body.tty ?? false,
            user: finalUser,
        )

        var containerConfiguration = ContainerConfiguration(id: id, image: img.description, process: processConfig)
        containerConfiguration.platform = requestedPlatform

        // Enable Rosetta when running amd64 images if on arm64 host
        if Platform.current.architecture == "arm64" && requestedPlatform.architecture == "amd64" {
            containerConfiguration.rosetta = true
        }

        // Handle hostname from request - ensure uniqueness to avoid collision
        let hostname = body.hostname.flatMap { $0.isEmpty ? nil : $0 } ?? "\(id)-\(UUID().uuidString.lowercased())"
        let requestedMacAddress: MACAddress? = try {
            guard let macAddress = body.macAddress, !macAddress.isEmpty else {
                return nil
            }
            try Utility.validMACAddress(macAddress)
            return try MACAddress(macAddress)
        }()
        let networkDisabled = body.networkDisabled ?? false

        if networkDisabled {
            let hasExplicitNetworkingConfig =
                (body.networkingConfig?.endpointsConfig?.isEmpty == false)
                || ((body.hostConfig?.networkMode?.isEmpty == false) && body.hostConfig?.networkMode != "none")
            let hasPublishedPorts = !(body.hostConfig?.portBindings?.isEmpty ?? true)
            let publishAllPorts = body.hostConfig?.publishAllPorts ?? false

            if hasExplicitNetworkingConfig || hasPublishedPorts || publishAllPorts || requestedMacAddress != nil {
                throw Abort(.badRequest, reason: "NetworkDisabled cannot be combined with explicit networking, published ports, or MacAddress")
            }
        }

        // Handle networking configuration from request
        if networkDisabled {
            containerConfiguration.networks = []
        } else if let networkingConfig = body.networkingConfig,
            let endpointsConfig = networkingConfig.endpointsConfig,
            !endpointsConfig.isEmpty
        {
            // Use networking config from request if provided
            containerConfiguration.networks = try endpointsConfig.map { (networkName, endpoint) in
                let macAddress = try validatedEndpointMacAddress(endpoint, fallback: requestedMacAddress)
                let options = attachmentOptions(hostname: hostname, macAddress: macAddress)
                return AttachmentConfiguration(network: networkName, options: options)
            }
        } else if let hostConfig = body.hostConfig,
            let networkMode = hostConfig.networkMode,
            !networkMode.isEmpty
        {
            // Use NetworkMode from HostConfig
            if networkMode == "none" {
                containerConfiguration.networks = []
            } else {
                containerConfiguration.networks = [
                    AttachmentConfiguration(network: networkMode, options: attachmentOptions(hostname: hostname, macAddress: requestedMacAddress))
                ]
            }
        } else {
            // Fall back to default network if no networking config provided
            containerConfiguration.networks = [AttachmentConfiguration(network: "default", options: attachmentOptions(hostname: hostname, macAddress: requestedMacAddress))]
        }

        containerConfiguration.publishedPorts = publishedPorts

        // Handle DNS configuration from request
        let nameservers = body.hostConfig?.dns ?? []
        let searchDomains = body.hostConfig?.dnsSearch ?? []
        let dnsOptions = body.hostConfig?.dnsOptions ?? []
        let domain = (body.domainname?.isEmpty == false) ? body.domainname : nil

        // Mirror containerization 0.31.0 DNS validation at the Docker API boundary so
        // invalid nameservers fail during create instead of surfacing later from guest
        // setup with a backend-specific error shape.
        try validateNameservers(nameservers)

        // Always set DNS configuration to ensure /etc/resolv.conf is created
        // Even if empty, this ensures the file exists in the container
        containerConfiguration.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: nameservers,
            domain: domain,
            searchDomains: searchDomains,
            options: dnsOptions
        )
        // NOTE: Apple container snapshots do not round-trip a number of Docker
        // create-only config fields directly. Preserve the accepted subset in
        // internal metadata labels so inspect/list routes can report them back
        // honestly without inventing unsupported runtime state.
        var labels = body.labels ?? [:]
        labels[SocktainerContainerMetadata.containerNameLabel] = containerName ?? id
        labels[SocktainerContainerMetadata.autoRemoveLabel] = (body.hostConfig?.autoRemove ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.openStdinLabel] = (body.openStdin ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.attachStdinLabel] = (body.attachStdin ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.attachStdoutLabel] = (body.attachStdout ?? true) ? "true" : "false"
        labels[SocktainerContainerMetadata.attachStderrLabel] = (body.attachStderr ?? true) ? "true" : "false"
        labels[SocktainerContainerMetadata.stdinOnceLabel] = (body.stdinOnce ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.argsEscapedLabel] = (body.argsEscaped ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.networkDisabledLabel] = (body.networkDisabled ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.privilegedLabel] = (body.hostConfig?.privileged ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.publishAllPortsLabel] = (body.hostConfig?.publishAllPorts ?? false) ? "true" : "false"
        labels[SocktainerContainerMetadata.readonlyRootfsLabel] = (body.hostConfig?.readonlyRootfs ?? false) ? "true" : "false"
        if let stopSignal = body.stopSignal, !stopSignal.isEmpty {
            labels[SocktainerContainerMetadata.stopSignalLabel] = stopSignal
        }
        if let stopTimeout = body.stopTimeout {
            labels[SocktainerContainerMetadata.stopTimeoutLabel] = String(stopTimeout)
        }
        if let macAddress = body.macAddress, !macAddress.isEmpty {
            labels[SocktainerContainerMetadata.macAddressLabel] = macAddress
        }
        if let cmd = body.cmd, let encoded = SocktainerContainerMetadata.encodeJSON(cmd) {
            labels[SocktainerContainerMetadata.cmdLabel] = encoded
        }
        if let entrypoint = body.entrypoint, let encoded = SocktainerContainerMetadata.encodeJSON(entrypoint) {
            labels[SocktainerContainerMetadata.entrypointLabel] = encoded
        }
        if let healthcheck = body.healthcheck,
            let encoded = SocktainerContainerMetadata.encodeJSON(healthcheck)
        {
            labels[SocktainerContainerMetadata.healthcheckLabel] = encoded
        }
        if let shell = body.shell, let encoded = SocktainerContainerMetadata.encodeJSON(shell) {
            labels[SocktainerContainerMetadata.shellLabel] = encoded
        }
        if let exposedPorts = body.exposedPorts,
            let encoded = SocktainerContainerMetadata.encodeJSON(Array(exposedPorts.keys).sorted())
        {
            labels[SocktainerContainerMetadata.exposedPortsLabel] = encoded
        }
        if let volumes = body.volumes,
            let encoded = SocktainerContainerMetadata.encodeJSON(Array(volumes.keys).sorted())
        {
            labels[SocktainerContainerMetadata.volumesLabel] = encoded
        }
        if let onBuild = body.onBuild, let encoded = SocktainerContainerMetadata.encodeJSON(onBuild) {
            labels[SocktainerContainerMetadata.onBuildLabel] = encoded
        }
        if let restartPolicy = body.hostConfig?.restartPolicy,
            let encoded = SocktainerContainerMetadata.encodeJSON(restartPolicy)
        {
            labels[SocktainerContainerMetadata.restartPolicyLabel] = encoded
        }
        if let binds = body.hostConfig?.binds,
            let encoded = SocktainerContainerMetadata.encodeJSON(binds)
        {
            labels[SocktainerContainerMetadata.bindsLabel] = encoded
        }
        if let consoleSize = body.hostConfig?.consoleSize,
            let encoded = SocktainerContainerMetadata.encodeJSON(consoleSize)
        {
            labels[SocktainerContainerMetadata.consoleSizeLabel] = encoded
        }
        containerConfiguration.labels = labels

        var resolvedMounts: [Filesystem] = []

        // Process bind mounts from HostConfig.Binds
        var volumesOrFs: [VolumeOrFilesystem] = []
        if let binds = body.hostConfig?.binds, !binds.isEmpty {
            volumesOrFs = try Parser.volumes(binds)
        }

        // Process mounts from HostConfig.Mounts
        var mountsOrFs: [VolumeOrFilesystem] = []
        if let mounts = body.hostConfig?.mounts, !mounts.isEmpty {
            // Separate volume mounts from other mount types
            let volumeMounts = mounts.filter { $0.type?.rawValue.lowercased() == "volume" }
            let otherMounts = mounts.filter { $0.type?.rawValue.lowercased() != "volume" }

            // Handle volume mounts using the volume format (source:destination)
            if !volumeMounts.isEmpty {
                let volumeStrings = volumeMounts.map { mount in
                    var volumeString = "\(mount.source ?? ""):\(mount.target ?? "")"
                    if mount.readOnly == true {
                        volumeString += ":ro"
                    }
                    return volumeString
                }
                let volumeMountsOrFs = try Parser.volumes(volumeStrings)
                mountsOrFs.append(contentsOf: volumeMountsOrFs)
            }

            // Handle other mount types (bind, tmpfs, etc.)
            if !otherMounts.isEmpty {
                let mountStrings = otherMounts.map { mount in
                    var components: [String] = []

                    // Convert Docker mount type to Parser-supported type
                    let mountType = mount.type?.rawValue.lowercased() == "bind" ? "bind" : (mount.type?.rawValue ?? "")
                    components.append("type=\(mountType)")

                    // Add source if specified
                    if let source = mount.source, !source.isEmpty {
                        components.append("source=\(source)")
                    }

                    // Add destination/target
                    components.append("destination=\(mount.target ?? "")")

                    // Add readonly flag if specified
                    if mount.readOnly == true {
                        components.append("ro")
                    }

                    return components.joined(separator: ",")
                }
                let otherMountsOrFs = try Parser.mounts(mountStrings)
                mountsOrFs.append(contentsOf: otherMountsOrFs)
            }
        }

        // Resolve volumes from both volumes and mounts
        for item in (volumesOrFs + mountsOrFs) {
            switch item {
            case .filesystem(let fs):
                resolvedMounts.append(fs)
            case .volume(let parsed):
                // Check if volume exists by listing all volumes and finding a match
                let existingVolumes = try await ClientVolume.list()
                let existingVolume = existingVolumes.first { $0.name == parsed.name }

                let volume: ContainerResource.Volume
                if let existing = existingVolume {
                    // Volume exists, use it
                    volume = existing
                } else {
                    // Volume doesn't exist, create it automatically (Docker behavior)
                    // might be revisited if https://github.com/apple/container/issues/690 is closed
                    req.logger.debug("Volume '\(parsed.name)' not found, creating it automatically")
                    volume = try await ClientVolume.create(
                        name: parsed.name,
                        driver: "local",
                        driverOpts: [:],
                        labels: [:]
                    )
                }

                let volumeMount = Filesystem.volume(
                    name: parsed.name,
                    format: volume.format,
                    source: volume.source,
                    destination: parsed.destination,
                    options: parsed.options
                )
                resolvedMounts.append(volumeMount)
            }
        }

        let mountedDestinations = Set(resolvedMounts.map(\.destination))
        if let declaredVolumes = body.volumes?.keys {
            for destination in declaredVolumes.sorted() where !mountedDestinations.contains(destination) {
                // Apple containers support volumes, but they do not natively model
                // Docker's anonymous-volume declaration from Config.Volumes. Emulate
                // it by creating a regular local volume with Docker's anonymous label.
                let volumeName = UUID().uuidString.lowercased()
                let volume = try await ClientVolume.create(
                    name: volumeName,
                    driver: "local",
                    driverOpts: [:],
                    labels: [anonymousVolumeLabel: ""]
                )

                let anonymousMount = Filesystem.volume(
                    name: volumeName,
                    format: volume.format,
                    source: volume.source,
                    destination: destination,
                    options: []
                )
                resolvedMounts.append(anonymousMount)
            }
        }

        containerConfiguration.mounts = resolvedMounts

        let options = ContainerCreateOptions(autoRemove: body.hostConfig?.autoRemove ?? false)
        let container: ContainerSnapshot
        do {
            let containerClient = ContainerClient()
            try await containerClient.create(configuration: containerConfiguration, options: options, kernel: kernel)
            container = try await containerClient.get(id: containerConfiguration.id)
            req.logger.debug("Container created successfully with ID: \(container.id)")
        } catch {
            req.logger.error("Failed to create container: \(error)")
            throw abortForCreateError(error)
        }

        let response = ContainerCreateResponse(
            id: container.id,
            warnings: []
        )

        if let broadcaster = req.eventBroadcaster {
            let eventLabels = SocktainerContainerMetadata.userVisibleLabels(from: container.configuration.labels)
            let event = DockerEvent.simpleEvent(
                id: container.id,
                type: "container",
                status: "create",
                from: container.configuration.image.reference,
                name: container.configuration.labels[SocktainerContainerMetadata.containerNameLabel] ?? container.id,
                image: container.configuration.image.reference,
                labels: eventLabels
            )
            await broadcaster.broadcast(event)
        } else {
            req.logger.warning("Event broadcaster not configured; skipping container create event")
        }

        return try await response.encodeResponse(status: .created, for: req)
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            try await handleCreateRequest(req, client: client)
        }
    }
}
// Function to convert PortBindings from HostConfig to PublishedPorts
/*

    // handle PortBindings from HostConfig
    // example:
    //     "PortBindings":{
    //      "5432/tcp":[
    //         {
    //            "HostIp":"",
    //            "HostPort":""
    //         }
    //      ]
    //   },

    // needs to be converted to
    "publishedPorts": [
        {
          "hostAddress": "0.0.0.0",
          "containerPort": 5432,
          "hostPort": 5432,
          "proto": "tcp"
        }
      ],
*/
private enum PortBindingConversionError: LocalizedError {
    case invalidPortSpec(String)
    case unsupportedProtocol(String)
    case invalidHostPort(String)

    var errorDescription: String? {
        switch self {
        case .invalidPortSpec(let value):
            return "Invalid PortBindings key: \(value)"
        case .unsupportedProtocol(let value):
            return "Unsupported PortBindings protocol: \(value)"
        case .invalidHostPort(let value):
            return "Invalid PortBindings host port: \(value)"
        }
    }
}

func convertPortBindings(from portBindings: [String: [PortBinding]]) throws -> [PublishPort] {
    var publishedPorts: [PublishPort] = []

    for (portSpec, bindings) in portBindings {
        // Parse the port specification (e.g., "5432/tcp")
        let components = portSpec.split(separator: "/")
        guard components.count == 2,
            let containerPort = UInt16(components[0])
        else {
            throw PortBindingConversionError.invalidPortSpec(portSpec)
        }

        let protoString = String(components[1])
        guard let proto = PublishProtocol(rawValue: protoString) else {
            throw PortBindingConversionError.unsupportedProtocol(protoString)
        }

        // Process each binding for this port
        for binding in bindings {
            // Use default values if not specified
            let hostAddress = binding.hostIp.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"

            // If HostPort is empty/nil, find an available port
            let hostPort: UInt16
            if let hostPortString = binding.hostPort, !hostPortString.isEmpty {
                guard let parsedPort = UInt16(hostPortString) else {
                    throw PortBindingConversionError.invalidHostPort(hostPortString)
                }
                hostPort = parsedPort
            } else {
                hostPort = UInt16(try findAvailablePort())
            }

            let publishPort = PublishPort(
                hostAddress: try IPAddress(hostAddress),
                hostPort: hostPort,
                containerPort: containerPort,
                proto: proto,
                count: 1
            )

            publishedPorts.append(publishPort)
        }
    }

    return publishedPorts
}
