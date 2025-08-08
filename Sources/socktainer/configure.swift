import Vapor

func configure(_ app: Application) async throws {
    let containerClient = ClientContainerService()
    let imageClient = ClientImageService()
    let healthCheckClient = ClientHealthCheckService()

    // /_ping
    try app.register(collection: HealthCheckPingRoute(client: healthCheckClient))

    // /events
    try app.register(collection: EventsRoute(client: healthCheckClient))

    // /containers
    try app.register(collection: ContainerListRoute(client: containerClient))
    try app.register(collection: ContainerInspectRoute(client: containerClient))
    try app.register(collection: ContainerStartRoute(client: containerClient))
    try app.register(collection: ContainerStopRoute(client: containerClient))
    try app.register(collection: ContainerDeleteRoute(client: containerClient))

    // /images
    try app.register(collection: ImageListRoute(client: imageClient))
    try app.register(collection: ImageDeleteRoute(client: imageClient))

    // /volumes
    try app.register(collection: VolumeListRoute())

    app.storage[EventBroadcasterKey.self] = EventBroadcaster()
}
