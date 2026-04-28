import Vapor

struct EventBroadcasterKey: StorageKey {
    typealias Value = EventBroadcaster
}

struct ActorAttributes: Encodable {
    let exitCode: String?
    let image: String?
    let name: String?
    let extra: [String: String]

    init(
        exitCode: String? = nil,
        image: String? = nil,
        name: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.exitCode = exitCode
        self.image = image
        self.name = name
        self.extra = extra
    }

    subscript(key: String) -> String? {
        switch key {
        case "exitCode":
            return exitCode
        case "image":
            return image
        case "name":
            return name
        default:
            return extra[key]
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encodeIfPresent(exitCode, forKey: .init("exitCode"))
        try container.encodeIfPresent(image, forKey: .init("image"))
        try container.encodeIfPresent(name, forKey: .init("name"))
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            try container.encode(value, forKey: .init(key))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct DockerActor: Encodable {
    let ID: String
    let Attributes: ActorAttributes
}

struct DockerEvent: Encodable {
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
    static func simpleEvent(
        id: String,
        type: String,
        status: String,
        from: String = "",
        name: String? = nil,
        image: String? = nil,
        exitCode: String? = nil,
        labels: [String: String] = [:]
    ) -> DockerEvent {
        let now = Date()
        let timeSeconds = Int(now.timeIntervalSince1970)
        let timeNano = UInt64(now.timeIntervalSince1970 * 1_000_000_000)

        let actorAttributes = ActorAttributes(
            exitCode: exitCode,
            image: image,
            name: name ?? id,
            extra: labels
        )
        let actor = DockerActor(
            ID: id,
            Attributes: actorAttributes
        )

        return DockerEvent(
            status: status,
            id: id,
            from: from,
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
    private var history: [DockerEvent] = []

    func subscribe(since: Date?) -> (replay: [DockerEvent], stream: AsyncStream<DockerEvent>) {
        let id = UUID()
        let replay = history.filter { event in
            guard let since else {
                return true
            }
            return eventDate(for: event) >= since
        }

        let stream = AsyncStream { continuation in
            continuations[id] = continuation

            continuation.onTermination = { @Sendable _ in
                Swift.Task {
                    await self.removeContinuation(id: id)
                }
            }
        }

        return (replay, stream)
    }

    func stream() -> AsyncStream<DockerEvent> {
        subscribe(since: nil).stream
    }

    func broadcast(_ event: DockerEvent) {
        history.append(event)
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func listenerCount() -> Int {
        continuations.count
    }

    private func addContinuation(id: UUID, _ continuation: AsyncStream<DockerEvent>.Continuation) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func eventDate(for event: DockerEvent) -> Date {
        Date(timeIntervalSince1970: Double(event.timeNano) / 1_000_000_000)
    }
}

extension Application {
    var eventBroadcaster: EventBroadcaster? {
        storage[EventBroadcasterKey.self]
    }
}

extension Request {
    var eventBroadcaster: EventBroadcaster? {
        application.eventBroadcaster
    }
}
