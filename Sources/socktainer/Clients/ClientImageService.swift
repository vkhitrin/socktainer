import ContainerClient

protocol ClientImageProtocol: Sendable {
    func list() async throws -> [ClientImage]
    func delete(id: String) async throws
}

enum ClientImageError: Error {
    case notFound(id: String)
}

struct ClientImageService: ClientImageProtocol {
    func list() async throws -> [ClientImage] {

        // filter out infra images
        let filteredImages = try await ClientImage.list().filter { img in
            !Utility.isInfraImage(name: img.reference)
        }

        return filteredImages
    }

    func delete(id: String) async throws {
        do {
            try await ClientImage.get(reference: id)
        } catch {
            // Handle specific error if needed
            throw ClientImageError.notFound(id: id)
        }

        try await ClientImage.delete(reference: id, garbageCollect: false)

    }

}
