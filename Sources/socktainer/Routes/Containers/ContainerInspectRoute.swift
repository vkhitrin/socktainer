import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationOCI
import Vapor

struct ContainerInspectRoute: RouteCollection {
    let client: ClientContainerProtocol
    let imageClient: ClientImageProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET,
            pattern: "/containers/{id}/json",
            use: ContainerInspectRoute.handler(client: client, imageClient: imageClient)
        )
    }
}

extension ContainerInspectRoute {
    private static let appSupportURL = URL(
        fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/com.apple.container"
    )
    private static let zeroTimestamp = "0001-01-01T00:00:00Z"
    private static let dockerDefaultMaskedPaths = [
        "/proc/acpi",
        "/proc/asound",
        "/proc/interrupts",
        "/proc/kcore",
        "/proc/keys",
        "/proc/latency_stats",
        "/proc/sched_debug",
        "/proc/scsi",
        "/proc/timer_list",
        "/proc/timer_stats",
        "/sys/devices/virtual/powercap",
        "/sys/firmware",
    ]
    private static let dockerDefaultReadonlyPaths = [
        "/proc/bus",
        "/proc/fs",
        "/proc/irq",
        "/proc/sys",
        "/proc/sysrq-trigger",
    ]

    private static func logPath(for container: ContainerSnapshot) -> String? {
        let candidate =
            appSupportURL
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(container.id, isDirectory: true)
            .appendingPathComponent("stdio.log", isDirectory: false)

        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }

        return candidate.path
    }

    private static func dockerName(for container: ContainerSnapshot) -> String {
        if let labelName = container.configuration.labels[SocktainerContainerMetadata.containerNameLabel], !labelName.isEmpty {
            return labelName
        }
        return container.id
    }

    private static func getUserString(from user: ProcessConfiguration.User) -> String? {
        switch user {
        case .raw(let userString):
            return userString.isEmpty ? nil : userString
        case .id(let uid, let gid):
            return "\(uid):\(gid)"
        }
    }

    private static func hostname(for container: ContainerSnapshot) -> String {
        if let attachmentHostname = container.networks.first?.hostname, !attachmentHostname.isEmpty {
            return attachmentHostname
        }
        return dockerName(for: container)
    }

    private static func autoRemove(for container: ContainerSnapshot) -> Bool? {
        ContainerLabelUtility.boolValue(
            container.configuration.labels[SocktainerContainerMetadata.autoRemoveLabel]
        )
    }

    private static func boolLabel(_ key: String, in container: ContainerSnapshot, default defaultValue: Bool) -> Bool {
        ContainerLabelUtility.boolValue(container.configuration.labels[key]) ?? defaultValue
    }

    private static func intLabel(_ key: String, in container: ContainerSnapshot) -> Int? {
        guard let value = container.configuration.labels[key] else {
            return nil
        }
        return Int(value)
    }

    private static func stringLabel(_ key: String, in container: ContainerSnapshot) -> String? {
        guard let value = container.configuration.labels[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func decodedLabel<T: Decodable>(_ key: String, in container: ContainerSnapshot, as type: T.Type) -> T? {
        SocktainerContainerMetadata.decodeJSON(container.configuration.labels[key], as: type)
    }

    private static func primaryEndpointSettings(
        from dockerNetworks: [String: EndpointSettings]
    ) -> EndpointSettings? {
        dockerNetworks.values.first
    }

    private static func setJSONValue(
        in object: inout [String: Any],
        path: [String],
        value: Any
    ) {
        guard let key = path.first else {
            return
        }

        if path.count == 1 {
            object[key] = value
            return
        }

        var child = object[key] as? [String: Any] ?? [:]
        setJSONValue(in: &child, path: Array(path.dropFirst()), value: value)
        object[key] = child
    }

    private static func dockerCompatInspectPayload(
        from response: ContainerInspectResponse,
        container: ContainerSnapshot,
        userVisibleLabels: [String: String],
        declaredVolumes: [String: JSONValue],
        execIDs: [String]?
    ) throws -> Response {
        let encoded = try JSONEncoder().encode(response)
        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw Abort(.internalServerError, reason: "Failed to encode container inspect response")
        }

        setJSONValue(
            in: &payload,
            path: ["Config", "Domainname"],
            value: container.configuration.dns?.domain ?? ""
        )
        setJSONValue(
            in: &payload,
            path: ["Config", "Labels"],
            value: userVisibleLabels
        )
        setJSONValue(
            in: &payload,
            path: ["Config", "User"],
            value: getUserString(from: container.configuration.initProcess.user) ?? ""
        )
        setJSONValue(
            in: &payload,
            path: ["Config", "Volumes"],
            value: declaredVolumes.isEmpty ? NSNull() : Dictionary(uniqueKeysWithValues: declaredVolumes.keys.map { ($0, [String: Any]()) })
        )
        setJSONValue(
            in: &payload,
            path: ["ExecIDs"],
            value: execIDs ?? NSNull()
        )

        let unsupportedHostConfigNullPaths: [[String]] = [
            ["HostConfig", "Binds"],
            ["HostConfig", "BlkioDeviceReadBps"],
            ["HostConfig", "BlkioDeviceReadIOps"],
            ["HostConfig", "BlkioDeviceWriteBps"],
            ["HostConfig", "BlkioDeviceWriteIOps"],
            ["HostConfig", "BlkioWeight"],
            ["HostConfig", "BlkioWeightDevice"],
            ["HostConfig", "CapAdd"],
            ["HostConfig", "CapDrop"],
            ["HostConfig", "Cgroup"],
            ["HostConfig", "CgroupnsMode"],
            ["HostConfig", "CgroupParent"],
            ["HostConfig", "ContainerIDFile"],
            ["HostConfig", "CpuCount"],
            ["HostConfig", "CpuPercent"],
            ["HostConfig", "CpuPeriod"],
            ["HostConfig", "CpuQuota"],
            ["HostConfig", "CpuRealtimePeriod"],
            ["HostConfig", "CpuRealtimeRuntime"],
            ["HostConfig", "CpusetCpus"],
            ["HostConfig", "CpusetMems"],
            ["HostConfig", "CpuShares"],
            ["HostConfig", "DeviceCgroupRules"],
            ["HostConfig", "DeviceRequests"],
            ["HostConfig", "Dns"],
            ["HostConfig", "DnsOptions"],
            ["HostConfig", "DnsSearch"],
            ["HostConfig", "ExtraHosts"],
            ["HostConfig", "GroupAdd"],
            ["HostConfig", "IOMaximumBandwidth"],
            ["HostConfig", "IOMaximumIOps"],
            ["HostConfig", "IpcMode"],
            ["HostConfig", "Isolation"],
            ["HostConfig", "Links"],
            ["HostConfig", "MemoryReservation"],
            ["HostConfig", "MemorySwap"],
            ["HostConfig", "MemorySwappiness"],
            ["HostConfig", "NanoCpus"],
            ["HostConfig", "OomKillDisable"],
            ["HostConfig", "OomScoreAdj"],
            ["HostConfig", "PidMode"],
            ["HostConfig", "PidsLimit"],
            ["HostConfig", "PortBindings"],
            ["HostConfig", "Runtime"],
            ["HostConfig", "SecurityOpt"],
            ["HostConfig", "ShmSize"],
            ["HostConfig", "UsernsMode"],
            ["HostConfig", "UTSMode"],
            ["HostConfig", "VolumeDriver"],
            ["HostConfig", "VolumesFrom"],
        ]
        for path in unsupportedHostConfigNullPaths {
            setJSONValue(in: &payload, path: path, value: NSNull())
        }

        // Apple does not expose Docker logging-driver, sandbox path-mask, or
        // low-level namespace metadata. Inspect keeps Docker's key shape here
        // using empty/default-compatible values rather than omitting them.
        setJSONValue(in: &payload, path: ["HostConfig", "LogConfig"], value: ["Config": [String: String](), "Type": ""])
        setJSONValue(in: &payload, path: ["HostConfig", "Devices"], value: [[String: Any]]())
        setJSONValue(in: &payload, path: ["HostConfig", "Ulimits"], value: [[String: Any]]())
        setJSONValue(in: &payload, path: ["HostConfig", "MaskedPaths"], value: dockerDefaultMaskedPaths)
        setJSONValue(in: &payload, path: ["HostConfig", "ReadonlyPaths"], value: dockerDefaultReadonlyPaths)
        setJSONValue(in: &payload, path: ["NetworkSettings", "SandboxID"], value: "")
        setJSONValue(in: &payload, path: ["NetworkSettings", "SandboxKey"], value: "")
        setJSONValue(in: &payload, path: ["NetworkSettings", "EndpointID"], value: "")
        setJSONValue(in: &payload, path: ["NetworkSettings", "Gateway"], value: "")
        setJSONValue(in: &payload, path: ["NetworkSettings", "GlobalIPv6Address"], value: "")
        setJSONValue(in: &payload, path: ["NetworkSettings", "IPAddress"], value: "")
        setJSONValue(in: &payload, path: ["NetworkSettings", "IPPrefixLen"], value: 0)
        setJSONValue(in: &payload, path: ["NetworkSettings", "IPv6Gateway"], value: "")
        setJSONValue(in: &payload, path: ["NetworkSettings", "MacAddress"], value: "")
        setJSONValue(in: &payload, path: ["State", "ExitCode"], value: 0)
        setJSONValue(in: &payload, path: ["State", "FinishedAt"], value: zeroTimestamp)
        setJSONValue(in: &payload, path: ["State", "Pid"], value: 0)

        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "application/json")
        response.body = .init(data: body)
        return response
    }

    static func handler(client: ClientContainerProtocol, imageClient: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let query = try req.query.decode(ContainerInspectQuery.self)
            let includeSize = query.size ?? false

            guard let container = try await client.getContainer(id: id) else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }

            let sizeRootFs: Int64?
            let sizeRw: Int64?
            if includeSize {
                let usage = try? await client.diskUsage(id: id)
                sizeRootFs = usage.map(Int64.init)
                sizeRw = usage.map(Int64.init)
            } else {
                sizeRootFs = nil
                sizeRw = nil
            }

            let exposedPortKeys =
                decodedLabel(
                    SocktainerContainerMetadata.exposedPortsLabel,
                    in: container,
                    as: [String].self
                ) ?? container.configuration.publishedPorts.map { "\($0.containerPort)/\($0.proto.rawValue)" }
            let exposedPorts = Dictionary(uniqueKeysWithValues: exposedPortKeys.map { ($0, JSONValue.dictionary([:])) })
            let declaredVolumeKeys =
                decodedLabel(
                    SocktainerContainerMetadata.volumesLabel,
                    in: container,
                    as: [String].self
                ) ?? []
            let declaredVolumes = Dictionary(uniqueKeysWithValues: declaredVolumeKeys.map { ($0, JSONValue.dictionary([:])) })
            let userVisibleLabels = SocktainerContainerMetadata.userVisibleLabels(from: container.configuration.labels)

            let containerConfig: ContainerConfig = ContainerConfig(
                hostname: hostname(for: container),
                domainname: container.configuration.dns?.domain,
                user: getUserString(from: container.configuration.initProcess.user),
                attachStdin: boolLabel(SocktainerContainerMetadata.attachStdinLabel, in: container, default: false),
                attachStdout: boolLabel(SocktainerContainerMetadata.attachStdoutLabel, in: container, default: true),
                attachStderr: boolLabel(SocktainerContainerMetadata.attachStderrLabel, in: container, default: true),
                exposedPorts: exposedPorts.isEmpty ? nil : exposedPorts,
                tty: container.configuration.initProcess.terminal,
                openStdin: boolLabel(SocktainerContainerMetadata.openStdinLabel, in: container, default: false),
                stdinOnce: boolLabel(SocktainerContainerMetadata.stdinOnceLabel, in: container, default: false),
                env: container.configuration.initProcess.environment.isEmpty ? nil : container.configuration.initProcess.environment,
                cmd: decodedLabel(SocktainerContainerMetadata.cmdLabel, in: container, as: [String].self)
                    ?? (container.configuration.initProcess.arguments.isEmpty ? nil : container.configuration.initProcess.arguments),
                healthcheck: decodedLabel(SocktainerContainerMetadata.healthcheckLabel, in: container, as: HealthConfig.self),
                argsEscaped: boolLabel(SocktainerContainerMetadata.argsEscapedLabel, in: container, default: false),
                image: container.configuration.image.reference,
                volumes: declaredVolumes.isEmpty ? nil : declaredVolumes,
                workingDir: container.configuration.initProcess.workingDirectory.isEmpty ? nil : container.configuration.initProcess.workingDirectory,
                entrypoint: decodedLabel(SocktainerContainerMetadata.entrypointLabel, in: container, as: [String].self)
                    ?? [container.configuration.initProcess.executable],
                networkDisabled: boolLabel(SocktainerContainerMetadata.networkDisabledLabel, in: container, default: container.networks.isEmpty),
                macAddress: stringLabel(SocktainerContainerMetadata.macAddressLabel, in: container),
                onBuild: decodedLabel(SocktainerContainerMetadata.onBuildLabel, in: container, as: [String].self),
                labels: userVisibleLabels.isEmpty ? nil : userVisibleLabels,
                stopSignal: stringLabel(SocktainerContainerMetadata.stopSignalLabel, in: container),
                stopTimeout: intLabel(SocktainerContainerMetadata.stopTimeoutLabel, in: container),
                shell: decodedLabel(SocktainerContainerMetadata.shellLabel, in: container, as: [String].self)
            )

            let mounts = ContainerPresentationUtility.dockerMounts(for: container)

            let portBindings = Dictionary(grouping: container.configuration.publishedPorts, by: { "\($0.containerPort)/\($0.proto.rawValue)" })
                .mapValues { bindings in
                    bindings.map { PortBinding(hostIp: $0.hostAddress.description, hostPort: "\($0.hostPort)") }
                }

            let hostConfig = HostConfig(
                networkMode: ContainerPresentationUtility.dockerNetworkMode(
                    for: container,
                    networkDisabledDefault: container.networks.isEmpty
                ),
                portBindings: portBindings.isEmpty ? nil : portBindings,
                restartPolicy: decodedLabel(SocktainerContainerMetadata.restartPolicyLabel, in: container, as: RestartPolicy.self),
                autoRemove: autoRemove(for: container),
                consoleSize: decodedLabel(SocktainerContainerMetadata.consoleSizeLabel, in: container, as: [Int].self),
                dns: container.configuration.dns?.nameservers.isEmpty == false ? container.configuration.dns?.nameservers : nil,
                dnsOptions: container.configuration.dns?.options.isEmpty == false ? container.configuration.dns?.options : nil,
                dnsSearch: container.configuration.dns?.searchDomains.isEmpty == false ? container.configuration.dns?.searchDomains : nil,
                privileged: boolLabel(SocktainerContainerMetadata.privilegedLabel, in: container, default: false),
                publishAllPorts: boolLabel(SocktainerContainerMetadata.publishAllPortsLabel, in: container, default: false),
                readonlyRootfs: boolLabel(SocktainerContainerMetadata.readonlyRootfsLabel, in: container, default: false)
            )
            let hostConfigWithBinds = HostConfig(
                binds: decodedLabel(SocktainerContainerMetadata.bindsLabel, in: container, as: [String].self),
                networkMode: hostConfig.networkMode,
                portBindings: hostConfig.portBindings,
                restartPolicy: hostConfig.restartPolicy,
                autoRemove: hostConfig.autoRemove,
                consoleSize: hostConfig.consoleSize,
                dns: hostConfig.dns,
                dnsOptions: hostConfig.dnsOptions,
                dnsSearch: hostConfig.dnsSearch,
                privileged: hostConfig.privileged,
                publishAllPorts: hostConfig.publishAllPorts,
                readonlyRootfs: hostConfig.readonlyRootfs
            )

            // Enhanced network settings with proper port mapping
            let dockerNetworks = ContainerPresentationUtility.dockerNetworkSettings(
                for: container,
                networkDisabledDefault: container.networks.isEmpty && container.configuration.networks.isEmpty
            )
            let primaryEndpoint = primaryEndpointSettings(from: dockerNetworks)
            let networkSettings = NetworkSettings(
                bridge: nil,
                sandboxID: nil,
                ports: portBindings,
                sandboxKey: nil,
                endpointID: primaryEndpoint?.endpointID,
                gateway: primaryEndpoint?.gateway,
                globalIPv6Address: primaryEndpoint?.globalIPv6Address,
                globalIPv6PrefixLen: Int(exactly: primaryEndpoint?.globalIPv6PrefixLen ?? 0),
                iPAddress: primaryEndpoint?.iPAddress,
                iPPrefixLen: primaryEndpoint?.iPPrefixLen,
                iPv6Gateway: primaryEndpoint?.iPv6Gateway,
                macAddress: primaryEndpoint?.macAddress,
                networks: dockerNetworks
            )

            let createdAt = AppleContainerTimestampResolver.containerCreationDate(container)
            let execIDs: [String]?
            if let execSessionManager = req.application.storage[ExecSessionManagerKey.self] {
                let runningExecIDs = await execSessionManager.runningExecIDs(containerId: container.id)
                execIDs = runningExecIDs.isEmpty ? nil : runningExecIDs
            } else {
                execIDs = nil
            }
            let completedAttachState: StoppedContainerCompletion? =
                if let attachSessionManager = req.application.storage[StoppedContainerAttachSessionManagerKey.self] {
                    await attachSessionManager.completion(containerID: container.id)
                } else {
                    nil
                }
            let imageManifestDescriptor = await ContainerPresentationUtility.resolvedImageManifestDescriptor(
                for: container,
                imageClient: imageClient,
                appSupportURL: appSupportURL
            )
            let stoppedExitStatus = await AppleContainerExitStatusResolver.resolve(for: container)
            let exitCode: Int? =
                if let completedAttachState {
                    Int(exactly: completedAttachState.exitCode)
                } else if let stoppedExitStatus {
                    stoppedExitStatus.code
                } else if container.status == .running {
                    0
                } else {
                    nil
                }
            let finishedAt: String? =
                if let completedAttachState {
                    AppleContainerTimestampResolver.iso8601Timestamp(completedAttachState.finishedAt)
                } else if let stoppedExitStatus {
                    stoppedExitStatus.finishedAt
                } else if container.status == .running {
                    zeroTimestamp
                } else {
                    nil
                }

            let containerState: ContainerState = ContainerState(
                status: .init(rawValue: container.status.mobyState),
                running: container.status == .running,
                paused: false,
                restarting: false,
                oOMKilled: false,
                dead: false,
                // NOTE: Apple container snapshots do not currently expose the init
                // process PID through the list/get container API surface we use here.
                // The bootstrap ClientProcess we track for started containers only
                // exposes an opaque container-service process identifier string, not
                // an OS PID, so inspect must keep Docker's State.Pid unset.
                pid: nil,
                // NOTE: The underlying runtime tracks exit status and exitedAt for the
                // init process, but ContainerSnapshot does not carry those fields.
                // Query the sandbox service directly for stopped containers when it
                // is still available; otherwise fall back to the attach flow that
                // socktainer tracks itself. After a daemon restart, those attach-flow
                // completions are gone and the Apple sandbox wait record may already
                // be unavailable, so stopped containers can fall back to Docker's
                // zero/empty defaults here.
                exitCode: exitCode,
                error: "",
                startedAt: container.startedDate.map { AppleContainerTimestampResolver.iso8601Timestamp($0) },
                finishedAt: finishedAt
            )

            let response = ContainerInspectResponse(
                id: container.id,
                created: AppleContainerTimestampResolver.iso8601Timestamp(createdAt),
                path: container.configuration.initProcess.executable,
                args: container.configuration.initProcess.arguments,
                state: containerState,
                image: container.configuration.image.digest,
                resolvConfPath: "/etc/resolv.conf",
                hostnamePath: "/etc/hostname",
                hostsPath: "/etc/hosts",
                // NOTE: Apple exposes a host-side stdio log for the VM-backed
                // container bundle. This is not Docker's json-file layout, but
                // it is the closest truthful host log path available here.
                logPath: logPath(for: container),
                name: "/" + dockerName(for: container),
                // NOTE: Restart counts are not surfaced by Apple container
                // snapshots. Keep this nil instead of fabricating zeroes.
                restartCount: 0,
                // NOTE: This is the closest truthful storage-driver label we can
                // report for the Apple-backed runtime. Docker-specific graph/driver
                // metadata is not exposed through the client API.
                driver: "apple-container",
                platform: "linux",
                imageManifestDescriptor: imageManifestDescriptor,
                mountLabel: "",
                processLabel: "",
                appArmorProfile: "",
                execIDs: execIDs,
                hostConfig: hostConfigWithBinds,
                // NOTE: Apple does not expose Docker graph-driver internals for
                // containers, but the v1.51 schema requires a Name/Data object.
                // Return a truthful backend-specific storage driver label with no
                // low-level metadata instead of omitting GraphDriver entirely.
                graphDriver: DriverData(name: "apple-container", data: [:]),
                sizeRw: sizeRw,
                sizeRootFs: sizeRootFs,
                mounts: mounts,
                config: containerConfig,
                networkSettings: networkSettings
            )

            return try dockerCompatInspectPayload(
                from: response,
                container: container,
                userVisibleLabels: userVisibleLabels,
                declaredVolumes: declaredVolumes,
                execIDs: execIDs
            )
        }
    }
}
