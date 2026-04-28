import ContainerAPIClient
import Foundation
import NIOCore
import Vapor

struct EventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/events", use: EventsRoute.handler(client: client))
    }

}

extension EventsRoute {
    private static let supportedFilterKeys: Set<String> = [
        "type",
        "event",
        "container",
        "image",
        "network",
        "volume",
        "daemon",
        "plugin",
        "node",
        "service",
        "secret",
        "config",
        "label",
        "scope",
    ]

    private static func parseEventTime(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return DockerBuildFilterUtility.parseUntilFilter(value)
    }

    private static func parseEventFilters(_ value: String?) throws -> [String: [String]] {
        guard let value, !value.isEmpty else {
            return [:]
        }

        guard let data = value.data(using: .utf8),
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Abort(.badRequest, reason: "invalid event filters")
        }

        var filters: [String: [String]] = [:]
        for (key, rawValue) in decoded {
            guard supportedFilterKeys.contains(key) else {
                throw Abort(.badRequest, reason: "unsupported event filter: \(key)")
            }
            if let array = rawValue as? [String] {
                filters[key] = array
            } else if let dictionary = rawValue as? [String: Any] {
                filters[key] = dictionary.compactMap { nestedKey, nestedValue in
                    (nestedValue as? Bool == true) ? nestedKey : nil
                }
            } else if let string = rawValue as? String {
                filters[key] = [string]
            } else {
                throw Abort(.badRequest, reason: "invalid event filter value for key \(key)")
            }
        }

        return filters
    }

    private static func actorAttributeValue(for key: String, event: DockerEvent) -> String? {
        event.Actor.Attributes[key]
    }

    private static func eventDate(for event: DockerEvent) -> Date {
        Date(timeIntervalSince1970: Double(event.timeNano) / 1_000_000_000)
    }

    private static func eventMatches(_ event: DockerEvent, filters: [String: [String]]) -> Bool {
        for (key, values) in filters {
            guard !values.isEmpty else { continue }

            let matched: Bool
            switch key {
            case "type":
                matched = values.contains(event.Type)
            case "event":
                matched = values.contains(event.Action) || values.contains(event.status)
            case "container", "network", "volume", "daemon", "plugin", "node", "service", "secret", "config":
                matched =
                    values.contains(event.id)
                    || values.contains(event.Actor.ID)
                    || values.contains(where: { $0 == event.Actor.Attributes.name })
            case "image":
                matched =
                    values.contains(event.id)
                    || values.contains(event.Actor.ID)
                    || values.contains(where: { $0 == event.Actor.Attributes.name })
                    || values.contains(where: { $0 == event.Actor.Attributes.image })
                    || values.contains(event.from)
            case "label":
                matched = values.allSatisfy { filter in
                    if let separator = filter.firstIndex(of: "=") {
                        let key = String(filter[..<separator])
                        let value = String(filter[filter.index(after: separator)...])
                        return actorAttributeValue(for: key, event: event) == value
                    }
                    guard let value = actorAttributeValue(for: filter, event: event) else {
                        return false
                    }
                    return !value.isEmpty
                }
            case "scope":
                matched = values.contains(event.scope)
            default:
                matched = false
            }

            if !matched {
                return false
            }
        }

        return true
    }

    private static func encodedEventLines(
        _ events: [DockerEvent],
        until: Date?,
        filters: [String: [String]]
    ) throws -> Data {
        var data = Data()
        for event in events {
            let date = eventDate(for: event)
            if let until, date > until {
                continue
            }
            if !eventMatches(event, filters: filters) {
                continue
            }

            let line = try JSONEncoder().encode(event)
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    static func handler(client: ClientHealthCheckProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let query = try req.query.decode(SystemEventsQuery.self)
            let since = parseEventTime(query.since)
            let until = parseEventTime(query.until)
            // NOTE: socktainer intentionally supports only the subset of Docker
            // event filters that can be evaluated against its live in-memory event
            // payloads. `since` replay is limited to the daemon's in-memory event
            // history, not a persisted event store across restarts.
            let filters = try parseEventFilters(query.filters)

            guard let broadcaster = req.eventBroadcaster else {
                throw Abort(.internalServerError, reason: "Event broadcaster not configured")
            }

            let (replayEvents, stream) = await broadcaster.subscribe(since: since)

            if let until, until <= Date() {
                let response = Response(status: .ok)
                response.headers.add(name: .contentType, value: "application/json")
                response.body = .init(data: try encodedEventLines(replayEvents, until: until, filters: filters))
                return response
            }

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(asyncStream: { writer in
                Swift.Task {
                    defer {
                        Swift.Task {
                            try? await writer.write(.end)
                        }
                    }

                    for event in replayEvents {
                        let eventDate = eventDate(for: event)
                        if let until, eventDate > until {
                            continue
                        }
                        if !eventMatches(event, filters: filters) {
                            continue
                        }

                        if let json = try? JSONEncoder().encode(event) {
                            var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                            buffer.writeBytes(json)
                            buffer.writeString("\n")
                            do {
                                try await writer.write(.buffer(buffer))
                            } catch {
                                return
                            }
                        }
                    }

                    if let until, until <= Date() {
                        return
                    }

                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await event in stream {
                                if Swift.Task.isCancelled {
                                    break
                                }

                                let eventDate = eventDate(for: event)
                                if let since, eventDate < since {
                                    continue
                                }
                                if let until, eventDate > until {
                                    break
                                }
                                if !eventMatches(event, filters: filters) {
                                    continue
                                }

                                if let json = try? JSONEncoder().encode(event) {
                                    var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                                    buffer.writeBytes(json)
                                    buffer.writeString("\n")
                                    do {
                                        try await writer.write(.buffer(buffer))
                                    } catch is IOError {
                                        req.logger.debug("Client disconnected (broken pipe)")
                                        break
                                    } catch let error as ChannelError where error == .ioOnClosedChannel {
                                        req.logger.debug("Client disconnected (closed channel)")
                                        break
                                    } catch {
                                        req.logger.warning("\(event) raised '\(error)'")
                                        break
                                    }
                                }
                            }
                        }

                        if let until {
                            let remaining = until.timeIntervalSinceNow
                            if remaining > 0 {
                                group.addTask {
                                    let sleepNanos = UInt64(remaining * 1_000_000_000)
                                    try? await Swift.Task.sleep(nanoseconds: sleepNanos)
                                }
                            }
                        }

                        await group.next()
                        group.cancelAll()
                    }
                }
            })

            return response

        }
    }
}
