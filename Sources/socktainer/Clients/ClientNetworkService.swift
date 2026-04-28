import ContainerAPIClient
import ContainerNetworkService
import ContainerResource
import Foundation
import Logging

protocol ClientNetworkProtocol: Sendable {
    func list(filters: String?, logger: Logger) async throws -> [Network]
    func getNetwork(id: String, logger: Logger) async throws -> Network?
    func delete(id: String, logger: Logger) async throws
    func create(name: String, labels: [String: String], logger: Logger) async throws -> NetworkCreateResponse
}

struct ClientNetworkService: ClientNetworkProtocol {
    private let networkClient = NetworkClient()

    private static func matchesDockerFilterPattern(_ value: String, pattern: String) -> Bool {
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, options: [], range: range) != nil
        }
        return value.localizedCaseInsensitiveContains(pattern)
    }

    func list(filters: String? = nil, logger: Logger) async throws -> [Network] {
        let networksList = try await networkClient.list()
        var allNetworks = networksList.map { Network(networkState: $0) }
        let containerClient = ClientContainerService()
        let allContainers = try await containerClient.list(showAll: true, filters: [:])

        // Map containers to networks
        for i in 0..<allNetworks.count {
            let network = allNetworks[i]
            var containersForNetwork: [String: NetworkContainer] = [:]
            for container in allContainers {
                for attachment in container.networks {
                    if attachment.network == network.id || attachment.network == network.name {
                        let nc = NetworkContainer(
                            name: container.id,
                            endpointID: nil,
                            macAddress: nil,
                            iPv4Address: String(describing: attachment.ipv4Address),
                            iPv6Address: nil
                        )
                        containersForNetwork[container.id] = nc
                        logger.debug("Container \(container.id) attached to network \(network.name ?? "<unknown>") (ID: \(network.id ?? "<unknown>"))")
                    }
                }
            }
            if !containersForNetwork.isEmpty {
                allNetworks[i] = Network(
                    name: network.name,
                    id: network.id,
                    created: network.created,
                    scope: network.scope,
                    driver: network.driver,
                    enableIPv4: network.enableIPv4,
                    enableIPv6: network.enableIPv6,
                    IPAM: network.IPAM,
                    internal: network.internal,
                    attachable: network.attachable,
                    ingress: network.ingress,
                    configFrom: network.configFrom,
                    configOnly: network.configOnly,
                    containers: containersForNetwork,
                    options: network.options,
                    labels: network.labels,
                    peers: network.peers
                )
            }
        }

        let filtersDict = try DockerNetworkFilterUtility.parseNetworkFilters(
            filtersParam: filters,
            defaultDangling: false,
            logger: logger
        )

        return allNetworks.filter { network in
            var excludedReason: String? = nil
            if let danglingArr = filtersDict["dangling"], !danglingArr.isEmpty {
                let isDangling = (network.containers == nil || network.containers?.isEmpty == true)
                let matchesDangling = danglingArr.contains { danglingStr in
                    let wantsDangling = danglingStr == "true" || danglingStr == "1"
                    return isDangling == wantsDangling
                }
                if !matchesDangling {
                    excludedReason = "dangling mismatch"
                }
            }
            if let driverArr = filtersDict["driver"], !driverArr.isEmpty {
                let matchesDriver = driverArr.contains { driver in
                    (network.driver ?? "").caseInsensitiveCompare(driver) == .orderedSame
                }
                if !matchesDriver { excludedReason = "driver mismatch" }
            }
            if let idArr = filtersDict["id"], !idArr.isEmpty {
                let matchesID = idArr.contains { id in
                    Self.matchesDockerFilterPattern(network.id ?? "", pattern: id)
                }
                if !matchesID { excludedReason = "id mismatch" }
            }
            if let labels = filtersDict["label"] {
                for label in labels {
                    if label.contains("=") {
                        let parts = label.split(separator: "=", maxSplits: 1)
                        let key = String(parts[0])
                        let value = String(parts[1])
                        if network.labels?[key] != value { excludedReason = "label key=value mismatch" }
                    } else {
                        if network.labels?[label] == nil { excludedReason = "label key missing" }
                    }
                }
            }
            if let nameArr = filtersDict["name"], !nameArr.isEmpty {
                let matchesName = nameArr.contains { name in
                    Self.matchesDockerFilterPattern(network.name ?? "", pattern: name)
                }
                if !matchesName { excludedReason = "name mismatch" }
            }
            if let scopeArr = filtersDict["scope"], !scopeArr.isEmpty {
                let matchesScope = scopeArr.contains { scope in
                    (network.scope ?? "").caseInsensitiveCompare(scope) == .orderedSame
                }
                if !matchesScope { excludedReason = "scope mismatch" }
            }
            if let typeArr = filtersDict["type"], !typeArr.isEmpty {
                let driver = network.driver ?? ""
                let isCustom = driver != "bridge" && driver != "host" && driver != "null"
                let matchesType = typeArr.contains { type in
                    (type == "custom" && isCustom) || (type == "builtin" && !isCustom)
                }
                if !matchesType { excludedReason = "type mismatch" }
            }
            if let reason = excludedReason {
                logger.debug("Excluding network \(network.name ?? "<unknown>") (ID: \(network.id ?? "<unknown>")) due to: \(reason)")
                return false
            }
            return true
        }
    }

    func getNetwork(id: String, logger: Logger) async throws -> Network? {
        let networks = try await list(logger: logger)
        return networks.first { network in
            network.id == id || (network.id?.hasPrefix(id) ?? false) || network.name == id
        }
    }

    func delete(id: String, logger: Logger) async throws {
        try await networkClient.delete(id: id)
        logger.debug("Deleted network with id: \(id)")
    }

    func create(name: String, labels: [String: String], logger: Logger) async throws -> NetworkCreateResponse {
        // NOTE: We will only create networks of type NAT for the time being (mimic the container CLI)
        let configuration = try NetworkConfiguration(
            id: name,
            mode: NetworkMode.nat,
            labels: ResourceLabels(labels),
            pluginInfo: NetworkPluginInfo(plugin: "container-network-vmnet")
        )
        _ = try await networkClient.create(configuration: configuration)
        logger.debug("Created network with id: \(configuration.id)")
        return NetworkCreateResponse(id: configuration.id, warning: "")
    }
}

extension Network {
    init(networkState: NetworkState) {
        let id: String
        let driver: String
        // Apple Container does not expose Docker bridge-driver metadata such as
        // `com.docker.network.bridge.*` or driver-specific IPAM/network options.
        // Keep `Options` empty here and let parity notes/documentation call out
        // that this is an Apple backend limitation rather than inventing values.
        let options: [String: String] = [:]
        let labels: [String: String]
        var subnet: String? = nil
        var gateway: String? = nil

        switch networkState {
        case .created(let config):
            id = config.id
            driver = String(describing: config.mode)
            subnet = config.ipv4Subnet.map { String(describing: $0) }
            labels = config.labels.dictionary
        case .running(let config, let status):
            id = config.id
            driver = String(describing: config.mode)
            subnet = config.ipv4Subnet.map { String(describing: $0) } ?? String(describing: status.ipv4Subnet)
            gateway = String(describing: status.ipv4Gateway)
            labels = config.labels.dictionary
        }

        let createdTimestamp = AppleContainerTimestampResolver.iso8601Timestamp(
            AppleContainerTimestampResolver.networkCreationDate(networkState)
        )

        self.init(
            name: id,
            id: id,
            created: createdTimestamp,
            scope: "local",
            driver: driver,
            enableIPv4: true,
            enableIPv6: false,
            IPAM: DockerNetworkIPAMMapper.networkIPAM(from: networkState),
            internal: false,
            attachable: false,
            ingress: false,
            // Docker includes ConfigFrom.Network as an empty string for regular
            // local networks that are not derived from a config-only source.
            configFrom: .init(network: ""),
            configOnly: false,
            containers: nil,
            options: options,
            labels: labels,
            peers: nil
        )
    }
}
