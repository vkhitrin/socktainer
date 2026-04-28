import Foundation
import Vapor

private func validateBooleanFilterValues(_ values: [String], key: String) throws {
    let supported: Set<String> = ["1", "0", "true", "false"]
    for value in values where !supported.contains(value.lowercased()) {
        throw Abort(.badRequest, reason: "Invalid \(key) filter value: \(value)")
    }
}

private func validateBooleanFilterKeys(_ values: [String], key: String, keys: Set<String>) throws {
    guard keys.contains(key) else {
        return
    }
    try validateBooleanFilterValues(values, key: key)
}

private func validateUntilFilterValues(_ values: [String]) throws {
    for untilValue in values where DockerBuildFilterUtility.parseUntilFilter(untilValue) == nil {
        throw Abort(.badRequest, reason: "Invalid until filter value: \(untilValue)")
    }
}

private func decodeFilterJSONObject(
    _ filtersParam: String?,
    logger: Logger,
    failureReason: String
) throws -> [String: Any]? {
    guard let filtersParam, let data = filtersParam.data(using: .utf8) else {
        return nil
    }
    guard let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        logger.warning("Failed to decode filters")
        throw Abort(.badRequest, reason: failureReason)
    }
    return decoded
}

private func validateFilterKeys(
    _ keys: Set<String>,
    allowedKeys: Set<String>,
    logger: Logger
) throws {
    guard keys.isSubset(of: allowedKeys) else {
        let invalidKeys = keys.subtracting(allowedKeys)
        logger.warning("Invalid filter key(s) found: \(invalidKeys)")
        throw Abort(.badRequest, reason: "Invalid filter key(s) found: \(invalidKeys)")
    }
}

private func coerceFilterValues(_ value: Any, key: String) throws -> (values: [String], shouldStore: Bool) {
    if let dict = value as? [String: Any] {
        let values = dict.compactMap { rawKey, rawValue in
            (rawValue as? Bool == true) ? rawKey : nil
        }
        return (values, !values.isEmpty)
    }
    if let arr = value as? [String] {
        return (arr, true)
    }
    if let str = value as? String {
        return ([str], true)
    }
    throw Abort(.badRequest, reason: "Invalid filter value for key \(key)")
}

private func parseFilterMap(
    _ filtersParam: String?,
    logger: Logger,
    failureReason: String,
    allowedKeys: Set<String>,
    transform: (_ key: String, _ values: [String]) throws -> [String]
) throws -> [String: [String]] {
    guard let filters = try decodeFilterJSONObject(filtersParam, logger: logger, failureReason: failureReason) else {
        return [:]
    }

    try validateFilterKeys(Set(filters.keys), allowedKeys: allowedKeys, logger: logger)

    var parsedFilters: [String: [String]] = [:]
    for (key, value) in filters {
        let (values, shouldStore) = try coerceFilterValues(value, key: key)
        guard shouldStore else {
            continue
        }
        parsedFilters[key] = try transform(key, values)
    }
    return parsedFilters
}

// utility for parsing network filters from query string
struct DockerNetworkFilterUtility {
    // parses network filters from a query string, optionally defaulting to dangling only
    // dangling networks are networks with no containers are attached to them
    static func parseNetworkFilters(filtersParam: String?, defaultDangling: Bool, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["name", "id", "label", "dangling", "driver", "scope", "type"]
        let parsedFilters = try parseFilterMap(
            filtersParam,
            logger: logger,
            failureReason: "Failed to decode network filters",
            allowedKeys: allowedKeys
        ) { key, values in
            if key == "dangling" {
                try validateBooleanFilterValues(values, key: key)
            }
            if key == "type" {
                let supportedTypes: Set<String> = ["custom", "builtin"]
                for type in values where !supportedTypes.contains(type) {
                    throw Abort(.badRequest, reason: "Invalid type filter value: \(type)")
                }
            }
            return values
        }

        if !parsedFilters.isEmpty {
            logger.debug("Decoded filters: \(parsedFilters)")
            return parsedFilters
        }

        if defaultDangling {
            logger.debug("No filters provided, defaulting to prune only dangling networks.")
            return ["dangling": ["true"]]
        }

        return parsedFilters
    }
}

// utility for parsing container filters from query string
struct DockerContainerFilterUtility {
    private static let supportedContainerStatuses: Set<String> = [
        "created",
        "restarting",
        "running",
        "removing",
        "paused",
        "exited",
        "dead",
    ]

    private static func validateContainerListFilterValues(_ values: [String], key: String) throws {
        switch key {
        case "status":
            for status in values where !supportedContainerStatuses.contains(status) {
                throw Abort(.badRequest, reason: "Unsupported container status filter: \(status)")
            }
        case "exited":
            for value in values where Int(value) == nil {
                throw Abort(.badRequest, reason: "Invalid exited filter value: \(value)")
            }
        default:
            break
        }
    }

    static func parseContainerPruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["until", "label"]
        let parsedFilters = try parseFilterMap(
            filtersParam,
            logger: logger,
            failureReason: "Failed to decode container prune filters",
            allowedKeys: allowedKeys
        ) { key, values in
            if key == "until" {
                for untilValue in values where DockerBuildFilterUtility.parseUntilFilter(untilValue) == nil {
                    throw Abort(.badRequest, reason: "Invalid until filter value: \(untilValue)")
                }
            }
            return values
        }
        logger.debug("Decoded container prune filters: \(parsedFilters)")
        return parsedFilters
    }

    static func parseContainerFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = [
            "status",
            "exited",
            "label",
            "name",
            "id",
            "ancestor",
            "before",
            "since",
            "health",
            "volume",
            "expose",
            "health",
            "isolation",
            "is-task",
            "network",
            "publish",
            "since",
        ]
        let parsedFilters = try parseFilterMap(
            filtersParam,
            logger: logger,
            failureReason: "Failed to decode container filters",
            allowedKeys: allowedKeys
        ) { key, values in
            try validateContainerListFilterValues(values, key: key)
            if key == "until" {
                for untilValue in values where DockerBuildFilterUtility.parseUntilFilter(untilValue) == nil {
                    throw Abort(.badRequest, reason: "Invalid until filter value: \(untilValue)")
                }
            }
            return values
        }
        logger.debug("Decoded filters: \(parsedFilters)")
        return parsedFilters
    }
}

// utility for parsing volume filters from query string
struct DockerVolumeFilterUtility {
    static func parsePruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["label", "all"]
        let parsedFilters = try parseFilterMap(
            filtersParam,
            logger: logger,
            failureReason: "Failed to decode volume prune filters",
            allowedKeys: allowedKeys
        ) { key, values in
            if key == "all" {
                try validateBooleanFilterValues(values, key: key)
            }
            return values
        }
        logger.debug("Decoded filters: \(parsedFilters)")
        return parsedFilters
    }

    static func parseVolumeFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["name", "driver", "label", "dangling"]
        let parsedFilters = try parseFilterMap(
            filtersParam,
            logger: logger,
            failureReason: "Failed to decode volume filters",
            allowedKeys: allowedKeys
        ) { key, values in
            if key == "dangling" {
                try validateBooleanFilterValues(values, key: key)
            }
            return values
        }
        logger.debug("Decoded filters: \(parsedFilters)")
        return parsedFilters
    }
}

struct DockerImageFilterUtility {
    static func parseImageListFilters(filterParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["before", "dangling", "label", "reference", "since", "until"]
        return try parseFilterMap(
            filterParam,
            logger: logger,
            failureReason: "Failed to decode image list filters",
            allowedKeys: allowedKeys
        ) { key, values in
            try validateBooleanFilterKeys(values, key: key, keys: ["dangling"])
            if key == "until" {
                try validateUntilFilterValues(values)
            }
            return values
        }
    }

    static func parseImagePruneFilters(filterParam: String?, logger: Logger) throws -> [String: [String]] {
        let allowedKeys: Set<String> = ["dangling", "label", "until"]

        do {
            return try parseFilterMap(
                filterParam,
                logger: logger,
                failureReason: "Failed to decode image prune filters",
                allowedKeys: allowedKeys
            ) { key, values in
                try validateBooleanFilterKeys(values, key: key, keys: ["dangling"])
                if key == "until" {
                    try validateUntilFilterValues(values)
                }
                return values
            }
        } catch {
            if let abort = error as? AbortError {
                throw abort
            }
            logger.warning("Failed to decode filters: \(error)")
            throw Abort(.badRequest, reason: "Failed to decode image prune filters")
        }
    }
}

// utility for parsing build cache filters from query string
struct DockerBuildFilterUtility {
    static func parseBuildPruneFilters(filtersParam: String?, logger: Logger) throws -> [String: [String]] {
        let supportedKeys: Set<String> = ["until", "id", "inuse", "parent", "type", "description", "shared", "private"]
        let parsedFilters = try parseFilterMap(
            filtersParam,
            logger: logger,
            failureReason: "Failed to decode build prune filters",
            allowedKeys: supportedKeys
        ) { key, values in
            try validateBooleanFilterKeys(values, key: key, keys: ["inuse", "shared", "private"])
            if key == "until" {
                try validateUntilFilterValues(values)
            }
            return values
        }
        logger.info("Parsed build prune filters: \(parsedFilters)")
        return parsedFilters
    }

    // Parse Docker's "until" filter value and convert to Date
    static func parseUntilFilter(_ untilValue: String) -> Date? {
        let now = Date()

        // Check if it's a duration string (e.g., "24h", "1h30m", "10m")
        if let duration = parseDuration(untilValue) {
            return now.addingTimeInterval(-duration)
        }

        // Check if it's a Unix timestamp
        if let timestamp = TimeInterval(untilValue) {
            return Date(timeIntervalSince1970: timestamp)
        }

        // Try parsing as ISO8601 date
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: untilValue) {
            return date
        }

        // Try parsing as RFC3339
        let rfc3339Formatter = DateFormatter()
        rfc3339Formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        if let date = rfc3339Formatter.date(from: untilValue) {
            return date
        }

        return nil
    }

    // Parse Go-style duration strings (e.g., "24h", "1h30m", "10m")
    private static func parseDuration(_ duration: String) -> TimeInterval? {
        var remainingString = duration
        var totalSeconds: TimeInterval = 0

        let units: [(suffix: String, multiplier: TimeInterval)] = [
            ("d", 86400),
            ("h", 3600),
            ("m", 60),
            ("s", 1),
        ]

        for (suffix, multiplier) in units {
            if let range = remainingString.range(of: suffix) {
                let numberPart = String(remainingString[..<range.lowerBound])
                if let value = TimeInterval(numberPart) {
                    totalSeconds += value * multiplier
                    remainingString = String(remainingString[range.upperBound...])
                }
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }
}
