import ContainerResource

enum DockerNetworkIPAMMapper {
    static func networkIPAM(from networkState: NetworkState) -> IPAM {
        let config: [IPAMConfig]

        switch networkState {
        case .created(let networkConfig):
            config = buildNetworkIPAMConfigs(
                ipv4Subnet: networkConfig.ipv4Subnet,
                ipv6Subnet: networkConfig.ipv6Subnet,
                gateway: nil
            )
        case .running(let networkConfig, let networkStatus):
            config = buildNetworkIPAMConfigs(
                ipv4Subnet: networkConfig.ipv4Subnet ?? networkStatus.ipv4Subnet,
                ipv6Subnet: networkConfig.ipv6Subnet ?? networkStatus.ipv6Subnet,
                gateway: networkStatus.ipv4Gateway.description
            )
        }

        return IPAM(
            driver: "default",
            config: config
        )
    }

    static func endpointSettings(from attachment: Attachment) -> EndpointSettings {
        EndpointSettings(
            iPAMConfig: EndpointIPAMConfig(
                iPv4Address: attachment.ipv4Address.address.description,
                iPv6Address: attachment.ipv6Address?.address.description,
                linkLocalIPs: nil
            ),
            links: nil,
            macAddress: attachment.macAddress?.description,
            aliases: nil,
            driverOpts: nil,
            gwPriority: nil,
            networkID: attachment.network,
            endpointID: nil,
            gateway: attachment.ipv4Gateway.description,
            iPAddress: attachment.ipv4Address.address.description,
            iPPrefixLen: Int(exactly: attachment.ipv4Address.prefix.length),
            iPv6Gateway: nil,
            globalIPv6Address: attachment.ipv6Address?.address.description,
            globalIPv6PrefixLen: attachment.ipv6Address.flatMap { Int64($0.prefix.length) },
            dNSNames: nil
        )
    }

    private static func buildNetworkIPAMConfigs(
        ipv4Subnet: Any?,
        ipv6Subnet: Any?,
        gateway: String?
    ) -> [IPAMConfig] {
        var configs: [IPAMConfig] = []

        if let ipv4Subnet {
            configs.append(
                IPAMConfig(
                    subnet: String(describing: ipv4Subnet),
                    iPRange: nil,
                    gateway: gateway,
                    auxiliaryAddresses: nil
                )
            )
        }

        if let ipv6Subnet {
            configs.append(
                IPAMConfig(
                    subnet: String(describing: ipv6Subnet),
                    iPRange: nil,
                    gateway: nil,
                    auxiliaryAddresses: nil
                )
            )
        }

        if configs.isEmpty, let gateway {
            configs.append(
                IPAMConfig(
                    subnet: nil,
                    iPRange: nil,
                    gateway: gateway,
                    auxiliaryAddresses: nil
                )
            )
        }

        return configs
    }
}
