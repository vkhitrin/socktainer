import ContainerAPIClient
import ContainerResource
import Vapor

struct InfoRoute: RouteCollection {
    private static func operatingSystem() -> String {
        "Apple container"
    }

    private static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func maskedProxyURL(_ value: String?) -> String? {
        guard let value else {
            return ""
        }
        guard !value.isEmpty else {
            return ""
        }

        guard var components = URLComponents(string: value) else {
            return value
        }

        if components.user != nil {
            components.user = "xxxxx"
        }
        if components.password != nil {
            components.password = "xxxxx"
        }

        return components.string ?? value
    }

    private static func plugins() -> PluginsInfo {
        PluginsInfo(
            volume: ["local"],
            // socktainer only accepts Docker's default bridge driver on network create.
            network: ["bridge"],
            authorization: [],
            log: ["json-file"]
        )
    }

    private static func registryConfig() -> RegistryServiceConfig {
        RegistryServiceConfig(
            insecureRegistryCIDRs: [],
            indexConfigs: [
                "docker.io": IndexInfo(
                    name: "docker.io",
                    mirrors: [],
                    secure: true,
                    official: true
                )
            ],
            mirrors: []
        )
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/info", use: InfoRoute.handler)
    }

    static func handler(_ req: Request) async throws -> SystemInfo {
        do {
            let containerClient = ClientContainerService()
            let allContainers = try await containerClient.list(showAll: true, filters: [:])
            let eventListenerCount =
                if let broadcaster = req.application.eventBroadcaster {
                    await broadcaster.listenerCount()
                } else {
                    0
                }

            // NOTE: Docker's /info payload contains daemon-level capabilities and
            // resource-control metadata that Apple container does not expose with
            // exact parity. Prefer conservative capability bits and explicit
            // warnings over advertising unsupported Docker semantics.
            return SystemInfo(
                ID: hostName(),
                containers: allContainers.count,
                containersRunning: allContainers.filter { $0.status == RuntimeStatus.running }.count,
                // Apple container doesn't support pausing containers
                containersPaused: 0,
                containersStopped: allContainers.filter { $0.status == RuntimeStatus.stopped }.count,
                images: try await ClientImageService().list().count,
                driver: "apple-container",
                driverStatus: [
                    ["Storage Backend", "Apple container"],
                    ["Kernel", getKernel()],
                ],
                dockerRootDir: try await ClientHealthCheck.ping().appRoot.path,
                plugins: plugins(),
                memoryLimit: false,
                swapLimit: false,
                kernelMemoryTCP: false,
                cpuCfsPeriod: false,
                cpuCfsQuota: false,
                cPUShares: false,
                cPUSet: false,
                pidsLimit: false,
                oomKillDisable: false,
                iPv4Forwarding: true,
                debug: isDebug(),
                nFd: isDebug() ? hostOpenFileDescriptorCount() : nil,
                nGoroutines: 0,
                systemTime: currentTime(),
                loggingDriver: "json-file",
                cgroupDriver: .cgroupfs,
                cgroupVersion: ._2,
                nEventsListener: eventListenerCount,
                kernelVersion: getKernel(),
                operatingSystem: operatingSystem(),
                oSVersion: operatingSystemVersion(),
                oSType: "linux",
                architecture: currentPlatform().architecture,
                NCPU: hostCPUCoreCount(),
                memTotal: Int64(hostPhysicalMemory()),
                indexServerAddress: "https://index.docker.io/v1/",
                registryConfig: registryConfig(),
                genericResources: [],
                httpProxy: maskedProxyURL(ProcessInfo.processInfo.environment["HTTP_PROXY"]),
                httpsProxy: maskedProxyURL(ProcessInfo.processInfo.environment["HTTPS_PROXY"]),
                noProxy: ProcessInfo.processInfo.environment["NO_PROXY"] ?? "",
                name: hostName(),
                labels: [],
                // Docker's experimental flags describe daemon feature mode, not general project maturity.
                experimentalBuild: false,
                serverVersion: getBuildVersion(),
                runtimes: [
                    "runc": Runtime(
                        path: "",
                        status: ["org.opencontainers.runtime-spec.features": ""]
                    ),
                    "io.containerd.runc.v2": Runtime(
                        path: "",
                        status: ["org.opencontainers.runtime-spec.features": ""]
                    ),
                ],
                defaultRuntime: "",
                swarm: SwarmInfo(
                    nodeID: "",
                    nodeAddr: "",
                    localNodeState: .inactive,
                    controlAvailable: false,
                    error: "",
                    remoteManagers: [],
                    nodes: nil,
                    managers: nil
                ),
                liveRestoreEnabled: false,
                isolation: .empty,
                initBinary: "",
                containerdCommit: Commit(ID: ""),
                runcCommit: Commit(ID: ""),
                initCommit: Commit(ID: ""),
                securityOptions: [],
                productLicense: "socktainer [Apache License 2.0], Apple container [Apache License 2.0]",
                firewallBackend: FirewallInfo(driver: ""),
                warnings: [
                    "WARNING: Apple container system info may differ",
                    "NOTE: socktainer is still under active development; some Docker API behavior may differ.",
                ],
                cDISpecDirs: [],
                containerd: ContainerdInfo(
                    address: "",
                    namespaces: ContainerdInfoNamespaces(
                        containers: "",
                        plugins: ""
                    )
                )
            )
        } catch {
            throw Abort(.internalServerError, reason: "Failed to generate system information")
        }
    }
}
