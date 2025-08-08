import Vapor

struct EventBroadcasterKey: StorageKey {
    typealias Value = EventBroadcaster
}

struct ActorAttributes: Codable {
    let containerExitCode: String
    let image: String
    let name: String
}

struct DockerActor: Codable {
    let ID: String
    let Attributes: ActorAttributes
}

struct DockerEvent: Codable {
    let status: String
    let id: String
    let from: String
    let `Type`: String
    let Action: String
    let Actor: DockerActor
    let scope: String
    let time: Int
    let timeNano: UInt64
}

extension DockerEvent {
    static func simpleEvent(id: String, type: String, status: String) -> DockerEvent {
        let now = Date()
        let timeSeconds = Int(now.timeIntervalSince1970)
        let timeNano = UInt64(now.timeIntervalSince1970 * 1_000_000_000)

        let actorAttributes = ActorAttributes(
            containerExitCode: "",  // empty if unknown
            image: "",
            name: id
        )
        let actor = DockerActor(
            ID: id,
            Attributes: actorAttributes
        )

        return DockerEvent(
            status: status,
            id: id,
            from: "",
            Type: type,
            Action: status,
            Actor: actor,
            scope: "local",
            time: timeSeconds,
            timeNano: timeNano
        )
    }
}

actor EventBroadcaster {
    private var continuations: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]

    func stream() -> AsyncStream<DockerEvent> {
        let id = UUID()

        return AsyncStream { continuation in
            // Safely register continuation inside the actor
            Task {
                self.addContinuation(id: id, continuation)
            }

            // Handle termination safely via actor
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    func broadcast(_ event: DockerEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func addContinuation(id: UUID, _ continuation: AsyncStream<DockerEvent>.Continuation) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
