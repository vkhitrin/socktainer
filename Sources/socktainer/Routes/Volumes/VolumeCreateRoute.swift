import Vapor

struct VolumeCreateRoute: RouteCollection {
    let client: ClientVolumeService
    init(client: ClientVolumeService) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/volumes/create", use: self.handler)
    }

    func handler(_ req: Request) async throws -> Response {
        let createRequest = try req.content.decode(VolumeCreateOptions.self)
        if createRequest.clusterVolumeSpec != nil {
            req.logger.debug("Ignoring ClusterVolumeSpec for local volume create")
        }
        if let driver = createRequest.driver, !driver.isEmpty, driver != "local" {
            throw Abort(.badRequest, reason: "Only the local volume driver is supported")
        }
        let resolvedName = createRequest.name.flatMap { $0.isEmpty ? nil : $0 } ?? "volume-\(UUID().uuidString)"
        let createOptions = VolumeCreateOptions(
            name: resolvedName,
            driver: createRequest.driver ?? "local",
            driverOpts: createRequest.driverOpts ?? [:],
            labels: createRequest.labels ?? [:]
        )
        let createdVolume = try await client.create(request: createOptions)
        if let broadcaster = req.eventBroadcaster {
            let event = DockerEvent.simpleEvent(
                id: createdVolume.name,
                type: "volume",
                status: "create",
                from: createdVolume.name,
                name: createdVolume.name,
                labels: createdVolume.labels
            )
            await broadcaster.broadcast(event)
        } else {
            req.logger.warning("Event broadcaster not configured; skipping volume create event")
        }
        let responseVolume = Volume(
            name: createdVolume.name,
            driver: createdVolume.driver,
            mountpoint: createdVolume.mountpoint,
            createdAt: createdVolume.createdAt,
            status: createdVolume.status,
            labels: createdVolume.labels,
            scope: createdVolume.scope,
            clusterVolume: createdVolume.clusterVolume,
            options: createdVolume.options,
            usageData: nil
        )
        return try await responseVolume.encodeResponse(status: .created, for: req)
    }
}
