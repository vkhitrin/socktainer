import ContainerResource
import ContainerizationExtras
import Testing

@testable import socktainer

struct DockerNetworkIPAMMapperTests {
    @Test
    func mapsRunningNetworkStateToDockerIPAM() throws {
        let config = try NetworkConfiguration(
            id: "testnet",
            mode: .nat,
            ipv4Subnet: CIDRv4("192.168.64.0/24"),
            ipv6Subnet: CIDRv6("fd3c:352:303c:7981::/64"),
            labels: try ResourceLabels([:]),
            pluginInfo: NetworkPluginInfo(plugin: "container-network-vmnet")
        )
        let status = try NetworkStatus(
            ipv4Subnet: CIDRv4("192.168.64.0/24"),
            ipv4Gateway: IPv4Address("192.168.64.1"),
            ipv6Subnet: CIDRv6("fd3c:352:303c:7981::/64")
        )

        let ipam = DockerNetworkIPAMMapper.networkIPAM(from: .running(config, status))

        #expect(ipam.driver == "default")
        #expect(ipam.config?.count == 2)
        #expect(ipam.config?.first?.subnet == "192.168.64.0/24")
        #expect(ipam.config?.first?.gateway == "192.168.64.1")
        #expect(ipam.config?.last?.subnet == "fd3c:352:303c:7981::/64")
        #expect(ipam.config?.last?.gateway == nil)
    }

    @Test
    func mapsAttachmentToEndpointIPAMConfig() throws {
        let attachment = Attachment(
            network: "testnet",
            hostname: "container-1",
            ipv4Address: try CIDRv4("192.168.64.10/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: try CIDRv6("fd00::10/64"),
            macAddress: try MACAddress("02:42:ac:11:00:02")
        )

        let endpoint = DockerNetworkIPAMMapper.endpointSettings(from: attachment)

        #expect(endpoint.iPAMConfig?.iPv4Address == "192.168.64.10")
        #expect(endpoint.iPAMConfig?.iPv6Address == "fd00::10")
        #expect(endpoint.gateway == "192.168.64.1")
        #expect(endpoint.iPAddress == "192.168.64.10")
        #expect(endpoint.iPPrefixLen == 24)
        #expect(endpoint.globalIPv6Address == "fd00::10")
        #expect(endpoint.globalIPv6PrefixLen == 64)
        #expect(endpoint.macAddress == "02:42:ac:11:00:02")
    }
}
