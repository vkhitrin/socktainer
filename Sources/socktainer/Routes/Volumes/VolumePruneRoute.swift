import Vapor

struct VolumePruneRoute: RouteCollection {
    let client: ClientVolumeService
    init(client: ClientVolumeService) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/volumes/prune", use: self.handler)
    }
    func handler(_ req: Request) async throws -> VolumePruneResponse {
        let logger = req.logger
        let query = try req.query.decode(VolumePruneQuery.self)
        var parsedFilters = try DockerVolumeFilterUtility.parsePruneFilters(filtersParam: query.filters, logger: logger)

        // Docker API v1.42+ prunes anonymous volumes only unless all=true is set.
        let pruneAll =
            parsedFilters["all"]?.contains {
                ["1", "true", "yes", "on"].contains($0.lowercased())
            } == true
        if !pruneAll {
            var labels = parsedFilters["label"] ?? []
            if !labels.contains("com.docker.volume.anonymous") {
                labels.append("com.docker.volume.anonymous")
            }
            parsedFilters["label"] = labels
        }

        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)
        let filteredVolumes = try await client.list(filters: filtersJSONString, logger: logger)

        var volumesDeleted: [String] = []
        var spaceReclaimed: Int64 = 0
        for volume in filteredVolumes {
            do {
                try await client.delete(name: volume.name)
                volumesDeleted.append(volume.name)
                if let broadcaster = req.eventBroadcaster {
                    let event = DockerEvent.simpleEvent(
                        id: volume.name,
                        type: "volume",
                        status: "destroy",
                        from: volume.name,
                        name: volume.name,
                        labels: volume.labels
                    )
                    await broadcaster.broadcast(event)
                }
                if let size = volume.usageData?.size, size > 0 {
                    spaceReclaimed += size
                }
            } catch {
                logger.warning("Failed to delete volume \(volume.name): \(error)")
            }
        }
        if let broadcaster = req.eventBroadcaster {
            let event = DockerEvent.simpleEvent(
                id: "volumes",
                type: "volume",
                status: "prune",
                from: "volumes",
                name: "volumes"
            )
            await broadcaster.broadcast(event)
        } else {
            req.logger.warning("Event broadcaster not configured; skipping volume prune event")
        }
        return VolumePruneResponse(
            volumesDeleted: volumesDeleted,
            spaceReclaimed: spaceReclaimed
        )
    }
}
