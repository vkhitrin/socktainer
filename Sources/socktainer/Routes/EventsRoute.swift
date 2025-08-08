import ContainerClient
import Vapor

struct EventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "events", use: EventsRoute.handler(client: client))
        routes.get("events", use: EventsRoute.handler(client: client))
    }

}

extension EventsRoute {
    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            let stream = await broadcaster.stream()

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(stream: { writer in
                Task {
                    for await event in stream {
                        if let json = try? JSONEncoder().encode(event) {
                            var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                            buffer.writeBytes(json)
                            buffer.writeString("\n")
                            writer.write(.buffer(buffer)).whenFailure { error in
                                // Optional: handle error
                                print("Write error: \(error)")
                            }
                        }
                    }
                }
            })

            /*
                response.body = .init(stream: { writer in
                    // Simulate streaming Docker events every second
                    req.eventLoop.scheduleRepeatedTask(initialDelay: .zero, delay: .seconds(1)) { task in
                        let event = generateFakeDockerEvent()
                        if let json = try? JSONEncoder().encode(event) {
                            var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                            buffer.writeBytes(json)
                            buffer.writeString("\n")
                            writer.write(.buffer(buffer))
                        }
                    }
            
                    // No return needed — just let it stream indefinitely
                })*/

            return response

        }
    }
}

/*
func generateFakeDockerEvent() -> DockerEvent {
    DockerEvent(
        status: "start",
        id: UUID().uuidString.prefix(12).description,
        from: "swift:vapor",
        time: Int(Date().timeIntervalSince1970)
    )
}

struct DockerEvent: Content {
    let status: String
    let id: String
    let from: String
    let time: Int
}*/
