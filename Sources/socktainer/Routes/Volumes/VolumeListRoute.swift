import Foundation
import Vapor

struct VolumeListRoute: RouteCollection {
    let client: ClientVolumeService
    init(client: ClientVolumeService) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/volumes", use: self.handler)
    }

    private func jsonResponse(_ object: Any, req: Request) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: object)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    func handler(_ req: Request) async throws -> Response {
        let logger = req.logger
        let query = try req.query.decode(VolumeListQuery.self)
        let parsedFilters = try DockerVolumeFilterUtility.parseVolumeFilters(filtersParam: query.filters, logger: logger)
        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)
        let filteredVolumes = try await client.list(filters: filtersJSONString, logger: logger)

        let response = VolumeListResponse(
            volumes: filteredVolumes,
            warnings: nil
        )
        let encoded = try JSONEncoder().encode(response)
        var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        object["Warnings"] = NSNull()
        return try jsonResponse(object, req: req)
    }
}
