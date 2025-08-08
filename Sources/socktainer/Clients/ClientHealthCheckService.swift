import ContainerClient

protocol ClientHealthCheckProtocol: Sendable {

    func ping() async throws
}

struct ClientHealthCheckService: ClientHealthCheckProtocol {
    func ping() async throws {
        try await ClientHealthCheck.ping(timeout: .seconds(1))
    }

}
