import ContainerizationError
import Foundation
import Logging

enum BuildctlUtility {
    static let executable = "/usr/bin/buildctl"

    struct PruneCommand {
        let executable: String
        let arguments: [String]

        var commandLine: String {
            ([self.executable] + arguments).joined(separator: " ")
        }
    }

    struct PruneRecord: Decodable {
        let id: String?
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case id
            case size
            case idLegacy = "ID"
            case sizeLegacy = "Size"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id =
                try container.decodeIfPresent(String.self, forKey: .id)
                ?? container.decodeIfPresent(String.self, forKey: .idLegacy)
            size =
                try container.decodeIfPresent(Int64.self, forKey: .size)
                ?? container.decodeIfPresent(Int64.self, forKey: .sizeLegacy)
        }
    }

    static func pruneCommand(from request: BuilderPruneRequest) throws -> PruneCommand {
        var arguments = [
            "--addr", "unix:///run/buildkit/buildkitd.sock",
            "prune",
            "--format", "{{json .}}",
        ]

        if request.all {
            arguments.append("--all")
        }

        if let keepStorageBytes = request.maxUsedSpace ?? request.keepStorage {
            arguments.append(contentsOf: ["--keep-storage", megabytesString(keepStorageBytes)])
        }

        if let reservedBytes = request.reservedSpace {
            arguments.append(contentsOf: ["--keep-storage-min", megabytesString(reservedBytes)])
        }

        if let minFreeBytes = request.minFreeSpace {
            arguments.append(contentsOf: ["--free-storage", megabytesString(minFreeBytes)])
        }

        if let untilValues = request.filters["until"], !untilValues.isEmpty {
            guard untilValues.count == 1 else {
                throw ContainerizationError(.invalidArgument, message: "build prune filter 'until' expects exactly one value")
            }
            let keepDuration = try keepDurationString(from: untilValues[0])
            arguments.append(contentsOf: ["--keep-duration", keepDuration])
        }

        for filter in toBuildkitFilters(request.filters) {
            arguments.append(contentsOf: ["--filter", filter])
        }

        return PruneCommand(executable: executable, arguments: arguments)
    }

    static func parsePruneOutput(_ output: String, logger: Logger) -> [PruneRecord] {
        var results: [PruneRecord] = []

        for line in output.split(whereSeparator: \Character.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == "{" else {
                continue
            }
            guard let data = trimmed.data(using: .utf8) else {
                continue
            }
            do {
                let item = try JSONDecoder().decode(PruneRecord.self, from: data)
                results.append(item)
            } catch {
                logger.debug("Failed to decode buildctl prune output line")
            }
        }

        return results
    }

    private static func toBuildkitFilters(_ filters: [String: [String]]) -> [String] {
        var result: [String] = []

        for (key, values) in filters {
            guard key != "until" else {
                continue
            }

            if values.isEmpty {
                result.append(key)
                continue
            }

            for value in values {
                if key == "id" {
                    result.append("\(key)~=\(value)")
                } else {
                    result.append("\(key)==\(value)")
                }
            }
        }

        return result
    }

    private static func keepDurationString(from untilValue: String) throws -> String {
        if parseDuration(untilValue) != nil {
            return untilValue
        }

        guard let untilDate = DockerBuildFilterUtility.parseUntilFilter(untilValue) else {
            throw ContainerizationError(.invalidArgument, message: "Invalid build prune filter 'until': \(untilValue)")
        }

        let seconds = max(0, Int(Date().timeIntervalSince(untilDate)))
        return "\(seconds)s"
    }

    private static func megabytesString(_ bytes: Int64) -> String {
        String(Double(bytes) / 1_000_000.0)
    }

    private static func parseDuration(_ duration: String) -> TimeInterval? {
        var remaining = duration
        var totalSeconds: TimeInterval = 0
        let units: [(String, TimeInterval)] = [("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)]

        for (suffix, multiplier) in units {
            while let range = remaining.range(of: suffix) {
                let number = String(remaining[..<range.lowerBound])
                guard let value = TimeInterval(number) else {
                    return nil
                }
                totalSeconds += value * multiplier
                remaining = String(remaining[range.upperBound...])
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }
}
