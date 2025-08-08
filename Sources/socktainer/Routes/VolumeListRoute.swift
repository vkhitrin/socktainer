import Vapor

struct VolumeInfo: Content {
    let CreatedAt: String
    let Driver: String
    let Labels: [String: String]?
    let Mountpoint: String
    let Name: String
    let Options: [String: String]
    let Scope: String
}

struct VolumeListResponse: Content {
    let Volumes: [VolumeInfo]
    let Warnings: [String]
}

struct VolumeListRoute: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "volumes", use: VolumeListRoute.handler())
        routes.get("volumes", use: VolumeListRoute.handler())
    }

}

extension VolumeListRoute {
    static func handler() -> @Sendable (Request) async throws -> VolumeListResponse {
        { req in
            let response = VolumeListResponse(
                Volumes: [],
                Warnings: []  // Add actual warnings if needed
            )

            return response
        }
    }
}
