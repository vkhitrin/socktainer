import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation

enum ContainerPresentationUtility {
    static func imageOCIDescriptor(
        from descriptor: Descriptor,
        appSupportURL: URL? = nil,
        parentDigest: String? = nil
    ) -> OCIDescriptor {
        OCIPresentationUtility.makeDescriptor(
            from: descriptor,
            appSupportURL: appSupportURL,
            parentDigest: parentDigest
        )
    }

    static func imageManifestDescriptor(
        for container: ContainerSnapshot,
        appSupportURL: URL? = nil
    ) -> OCIDescriptor {
        let descriptor = container.configuration.image.descriptor
        return imageOCIDescriptor(
            from: descriptor,
            appSupportURL: appSupportURL,
            parentDigest: container.configuration.image.digest
        )
    }

    static func resolvedImageManifestDescriptor(
        for container: ContainerSnapshot,
        imageClient: ClientImageProtocol,
        appSupportURL: URL? = nil
    ) async -> OCIDescriptor {
        do {
            let images = try await imageClient.list(includeSystemImages: true)
            if let image = images.first(where: { $0.digest == container.configuration.image.digest }) {
                let index = try await image.index()
                let details = try await image.details()
                if let manifestDescriptor = index.manifests.first(where: {
                    $0.annotations?["vnd.docker.reference.type"] != "attestation-manifest"
                        && $0.platform == container.platform
                }) {
                    return imageOCIDescriptor(
                        from: manifestDescriptor,
                        appSupportURL: appSupportURL,
                        parentDigest: details.index.digest
                    )
                }
            }
        } catch {
        }

        return imageManifestDescriptor(for: container, appSupportURL: appSupportURL)
    }

    static func dockerNetworkName(_ networkName: String) -> String {
        networkName
    }

    static func emptyEndpointSettings() -> EndpointSettings {
        EndpointSettings()
    }

    private static func networkDisabledLabelValue(for container: ContainerSnapshot) -> Bool? {
        ContainerLabelUtility.boolValue(
            container.configuration.labels[SocktainerContainerMetadata.networkDisabledLabel]
        )
    }

    private static func liveDockerNetworkSettings(for container: ContainerSnapshot) -> [String: EndpointSettings]? {
        guard !container.networks.isEmpty else {
            return nil
        }

        return Dictionary(
            uniqueKeysWithValues: container.networks.map { attachment in
                let endpoint = DockerNetworkIPAMMapper.endpointSettings(from: attachment)
                return (dockerNetworkName(attachment.network), endpoint)
            }
        )
    }

    private static func configuredDockerNetworkSettings(for container: ContainerSnapshot) -> [String: EndpointSettings]? {
        guard let configuredNetwork = container.configuration.networks.first?.network else {
            return nil
        }

        return [dockerNetworkName(configuredNetwork): emptyEndpointSettings()]
    }

    static func dockerName(for container: ContainerSnapshot) -> String {
        if let labelName = container.configuration.labels[SocktainerContainerMetadata.containerNameLabel], !labelName.isEmpty {
            return labelName
        }
        return container.id
    }

    static func dockerStatus(for container: ContainerSnapshot, completion: StoppedContainerCompletion?) -> String {
        func ageString(since date: Date) -> String {
            let seconds = max(0, Int(Date().timeIntervalSince(date)))
            if seconds < 60 {
                return seconds == 1 ? "1 second" : "\(seconds) seconds"
            }
            let minutes = seconds / 60
            if minutes < 60 {
                return minutes == 1 ? "1 minute" : "\(minutes) minutes"
            }
            let hours = minutes / 60
            if hours < 24 {
                return hours == 1 ? "1 hour" : "\(hours) hours"
            }
            let days = hours / 24
            return days == 1 ? "1 day" : "\(days) days"
        }

        switch container.status {
        case .running:
            if let started = container.startedDate {
                return "Up \(ageString(since: started))"
            }
            return "Up"
        case .stopped:
            if let completion {
                return "Exited (\(completion.exitCode)) \(ageString(since: completion.finishedAt)) ago"
            }
            if let created = AppleContainerTimestampResolver.containerCreationDate(container) {
                return "Exited \(ageString(since: created)) ago"
            }
            return "Exited"
        case .stopping:
            return "Removal In Progress"
        case .unknown:
            return "Created"
        }
    }

    static func dockerNetworkMode(for container: ContainerSnapshot) -> String {
        sharedDockerNetworkMode(for: container, networkDisabledDefault: nil)
    }

    static func dockerNetworkMode(
        for container: ContainerSnapshot,
        networkDisabledDefault defaultValue: Bool
    ) -> String {
        sharedDockerNetworkMode(for: container, networkDisabledDefault: defaultValue)
    }

    static func dockerNetworkSettings(for container: ContainerSnapshot) -> [String: EndpointSettings] {
        sharedDockerNetworkSettings(for: container, networkDisabledDefault: nil)
    }

    static func dockerNetworkSettings(
        for container: ContainerSnapshot,
        networkDisabledDefault defaultValue: Bool
    ) -> [String: EndpointSettings] {
        sharedDockerNetworkSettings(for: container, networkDisabledDefault: defaultValue)
    }

    static func dockerMounts(for container: ContainerSnapshot) -> [MountPoint] {
        container.configuration.mounts.map { mount in
            let mountType: MountType
            let mountName: String?
            let driver: String?

            switch mount.type {
            case .block:
                mountType = .bind
                mountName = nil
                driver = nil
            case .volume(let name, _, _, _):
                mountType = .volume
                mountName = name
                driver = "local"
            case .virtiofs:
                mountType = .bind
                mountName = nil
                driver = nil
            case .tmpfs:
                mountType = .tmpfs
                mountName = nil
                driver = nil
            }

            let isReadOnly = mount.options.readonly
            return MountPoint(
                type: mountType,
                name: mountName,
                source: mount.source,
                destination: mount.destination,
                driver: driver,
                mode: isReadOnly ? "ro" : "rw",
                RW: !isReadOnly,
                propagation: nil
            )
        }
    }

    static func containerSummary(
        from container: ContainerSnapshot,
        size: Int64?,
        completion: StoppedContainerCompletion?,
        imageManifestDescriptor: OCIDescriptor?
    ) -> ContainerSummary {
        let ports = container.configuration.publishedPorts.map { port in
            Port(
                IP: port.hostAddress.description,
                privatePort: Int(port.containerPort),
                publicPort: Int(port.hostPort),
                type: .init(rawValue: port.proto.rawValue) ?? .tcp
            )
        }
        let networkMode = dockerNetworkMode(for: container)
        let networkSettings = dockerNetworkSettings(for: container)
        let createdTimestamp = AppleContainerTimestampResolver.unixTimestampSeconds(
            AppleContainerTimestampResolver.containerCreationDate(container)
        )
        let dockerName = dockerName(for: container)
        let userVisibleLabels = SocktainerContainerMetadata.userVisibleLabels(from: container.configuration.labels)

        return ContainerSummary(
            id: container.id,
            names: ["/" + dockerName],
            image: container.configuration.image.reference,
            imageID: container.configuration.image.digest,
            imageManifestDescriptor: imageManifestDescriptor,
            command: ([container.configuration.initProcess.executable] + container.configuration.initProcess.arguments).joined(separator: " "),
            created: createdTimestamp,
            ports: ports,
            sizeRw: size,
            sizeRootFs: size,
            labels: userVisibleLabels,
            state: .init(rawValue: container.status.mobyState),
            status: dockerStatus(for: container, completion: completion),
            hostConfig: ContainerSummaryHostConfig(networkMode: networkMode, annotations: nil),
            networkSettings: ContainerSummaryNetworkSettings(networks: networkSettings.isEmpty ? nil : networkSettings),
            mounts: dockerMounts(for: container)
        )
    }

    private static func sharedDockerNetworkMode(
        for container: ContainerSnapshot,
        networkDisabledDefault defaultValue: Bool?
    ) -> String {
        if let disabled = networkDisabledLabelValue(for: container) {
            if disabled {
                return "none"
            }
        } else if defaultValue != nil {
            if defaultValue == true || container.networks.isEmpty {
                return "none"
            }
        } else if container.networks.isEmpty {
            return "none"
        }

        if let networkName = container.networks.first?.network {
            return dockerNetworkName(networkName)
        }
        if let configuredNetwork = container.configuration.networks.first?.network {
            return dockerNetworkName(configuredNetwork)
        }
        return "default"
    }

    private static func sharedDockerNetworkSettings(
        for container: ContainerSnapshot,
        networkDisabledDefault defaultValue: Bool?
    ) -> [String: EndpointSettings] {
        if let liveNetworks = liveDockerNetworkSettings(for: container) {
            return liveNetworks
        }

        if let disabled = networkDisabledLabelValue(for: container) {
            if disabled {
                return [:]
            }
        } else if defaultValue == true {
            return [:]
        }

        if let configuredNetworks = configuredDockerNetworkSettings(for: container) {
            return configuredNetworks
        }

        return [:]
    }
}
