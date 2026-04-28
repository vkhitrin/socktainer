import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

// Protocol for volume operations
protocol ClientVolumeProtocol: Sendable {
    func create(request: VolumeCreateOptions) async throws -> Volume
    func delete(name: String) async throws
    func list(filters: String?, logger: Logger) async throws -> [Volume]
    func inspect(name: String) async throws -> Volume
}

struct ClientVolumeService: ClientVolumeProtocol {
    func create(request: VolumeCreateOptions) async throws -> Volume {
        let result = try await ClientVolume.create(
            name: request.name ?? "volume-\(UUID().uuidString)",
            driver: request.driver ?? "local",
            driverOpts: request.driverOpts ?? [:],
            labels: request.labels ?? [:]
        )
        return try await Self.enrich(result, refCounts: [:])
    }

    func delete(name: String) async throws {
        try await ClientVolume.delete(name: name)
    }

    func list(filters: String?, logger: Logger) async throws -> [Volume] {
        let results = try await ClientVolume.list()
        let containers = try? await ContainerClient().list()
        let refCounts = Dictionary(
            grouping: (containers ?? []).flatMap { container in
                container.configuration.mounts.compactMap { mount -> String? in
                    guard mount.isVolume else { return nil }
                    return mount.volumeName
                }
            },
            by: { $0 }
        ).mapValues { Int64($0.count) }
        let volumes = try await withThrowingTaskGroup(of: Volume.self) { group in
            for result in results {
                group.addTask {
                    try await Self.enrich(result, refCounts: refCounts)
                }
            }

            var enriched: [Volume] = []
            for try await volume in group {
                enriched.append(volume)
            }
            return enriched
        }
        let referencedVolumeNames = Set<String>(
            (containers ?? []).flatMap { container in
                container.configuration.mounts.compactMap { mount in
                    guard mount.isVolume else { return nil }
                    return mount.volumeName
                }
            }
        )
        var parsedFilters: [String: [String]] = [:]
        var labelDictFilter: [String: Any]? = nil
        if let filters = filters, !filters.isEmpty, filters != "{}" {
            guard let data = filters.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            else {
                return []
            }
            for (key, value) in decoded {
                if key == "label", let dict = value as? [String: Any] {
                    labelDictFilter = dict
                } else if let arr = value as? [String] {
                    parsedFilters[key] = arr
                } else if let dict = value as? [String: Any] {
                    let keys = dict.compactMap { (key, value) in
                        (value as? Bool == true) ? key : nil
                    }
                    if !keys.isEmpty {
                        parsedFilters[key] = keys
                    }
                }
            }
        }
        if parsedFilters.isEmpty && labelDictFilter == nil {
            return volumes
        }
        // Filtering logic
        let filteredVolumes = volumes.filter { volume in
            var matches = true
            if let names = parsedFilters["name"], !names.isEmpty {
                matches = matches && names.contains(where: { volume.name.contains($0) })
            }
            if let drivers = parsedFilters["driver"], !drivers.isEmpty {
                matches = matches && drivers.contains(volume.driver)
            }
            if let labels = parsedFilters["label"], !labels.isEmpty {
                let volumeLabels = volume.labels
                let labelMatches = labels.allSatisfy { labelFilter in
                    if let separatorIndex = labelFilter.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                        let key = String(labelFilter[..<separatorIndex])
                        let value = String(labelFilter[labelFilter.index(after: separatorIndex)...])
                        return volumeLabels[key] == value
                    }
                    return volumeLabels.keys.contains(labelFilter)
                }
                matches = matches && labelMatches
            }
            if let labelDict = labelDictFilter {
                let volumeLabels = volume.labels
                let labelMatches = labelDict.allSatisfy { (key, value) in
                    if let volumeValue = volumeLabels[key] {
                        // Compare as string
                        return String(describing: volumeValue) == String(describing: value)
                    }
                    return false
                }
                matches = matches && labelMatches
            }
            if let dangling = parsedFilters["dangling"], !dangling.isEmpty {
                let isDangling = !referencedVolumeNames.contains(volume.name)
                let matchesDangling = dangling.contains { value in
                    let wantsDangling = ["1", "true", "yes", "on"].contains(value.lowercased())
                    return isDangling == wantsDangling
                }
                matches = matches && matchesDangling
            }
            return matches
        }
        return filteredVolumes
    }

    func inspect(name: String) async throws -> Volume {
        let result = try await ClientVolume.inspect(name)
        let containers = try? await ContainerClient().list()
        let refCount = Int64(
            (containers ?? []).flatMap { container in
                container.configuration.mounts.compactMap { mount -> String? in
                    guard mount.isVolume else { return nil }
                    return mount.volumeName
                }
            }.filter { $0 == result.name }.count
        )
        return try await Self.enrich(result, refCounts: [result.name: refCount])
    }

    private static func enrich(_ v: ContainerResource.Volume, refCounts: [String: Int64]) async throws -> Volume {
        let size = try await ClientVolume.volumeDiskUsage(name: v.name)
        return Volume(
            name: v.name,
            driver: v.driver,
            mountpoint: v.source,
            createdAt: ISO8601DateFormatter().string(from: v.createdAt),
            status: nil,
            labels: v.labels,
            scope: .local,
            clusterVolume: nil,
            options: v.options,
            usageData: VolumeUsageData(
                size: Int64(clamping: size),
                refCount: refCounts[v.name] ?? 0
            )
        )
    }
}
