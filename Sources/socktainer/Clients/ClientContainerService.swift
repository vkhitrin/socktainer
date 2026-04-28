import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation
import Vapor

protocol ClientContainerProtocol: Sendable {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot]
    func getContainer(id: String) async throws -> ContainerSnapshot?
    func diskUsage(id: String) async throws -> UInt64
    func enforceContainerRunning(container: ContainerSnapshot) throws

    func start(id: String, detachKeys: String?, startedSessionManager: StartedContainerSessionManager?) async throws
    func stop(id: String, signal: String?, timeout: Int?) async throws
    func restart(id: String, signal: String?, timeout: Int?) async throws
    func kill(id: String, signal: String?) async throws
    func delete(id: String) async throws
    func wait(id: String, condition: ContainerWaitCondition, startedSessionManager: StartedContainerSessionManager?) async throws -> ContainerWaitResponse
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64)
}

enum ClientContainerError: Error {
    case notFound(id: String)
    case notRunning(id: String)
}

struct ClientContainerService: ClientContainerProtocol {
    private let containerClient = ContainerClient()
    // Apple Container's public list/get APIs expose the buildkit builder container
    // alongside user containers; they do not provide a separate "infrastructure"
    // view we can exclude server-side. Hide that backend container from the
    // Docker-facing container surface here.
    private let infrastructureContainerIDs: Set<String> = ["buildkit"]

    private func isInfrastructureContainer(_ container: ContainerSnapshot) -> Bool {
        infrastructureContainerIDs.contains(container.id)
    }

    private func dockerName(for container: ContainerSnapshot) -> String {
        if let labelName = container.configuration.labels[SocktainerContainerMetadata.containerNameLabel], !labelName.isEmpty {
            return labelName
        }
        return container.id
    }

    private func matchesDockerNameFilter(_ filter: String, container: ContainerSnapshot) -> Bool {
        let name = dockerName(for: container)
        let slashPrefixedName = "/" + name

        guard let regex = try? NSRegularExpression(pattern: filter) else {
            return name.contains(filter) || slashPrefixedName.contains(filter)
        }

        let searchRange = NSRange(location: 0, length: slashPrefixedName.utf16.count)
        return regex.firstMatch(in: slashPrefixedName, options: [], range: searchRange) != nil
    }

    private func matchesContainerReference(_ reference: String, container: ContainerSnapshot) -> Bool {
        let name = dockerName(for: container)
        return container.id == reference || container.id.hasPrefix(reference) || name == reference || "/" + name == reference
    }

    private func userVisibleLabels(for container: ContainerSnapshot) -> [String: String] {
        SocktainerContainerMetadata.userVisibleLabels(from: container.configuration.labels)
    }

    private func matchesLabelFilter(_ filter: String, labels: [String: String], allowNotEquals: Bool) -> Bool {
        if allowNotEquals, let range = filter.range(of: "!=") {
            let key = String(filter.prefix(upTo: range.lowerBound))
            let value = String(filter.suffix(from: range.upperBound))
            guard !value.isEmpty else {
                return !labels.keys.contains(key)
            }
            return labels[key] != value
        }

        guard let eqIdx = filter.firstIndex(of: "=") else {
            return labels.keys.contains(filter)
        }

        let key = String(filter.prefix(upTo: eqIdx))
        let value = String(filter.suffix(from: filter.index(after: eqIdx)))
        return labels[key] == value
    }

    private func matchesLabelFilters(_ filters: [String], labels: [String: String], allowNotEquals: Bool) -> Bool {
        filters.allSatisfy { filter in
            matchesLabelFilter(filter, labels: labels, allowNotEquals: allowNotEquals)
        }
    }

    private func matchesPortFilter(port: UInt16, proto: String, filter: String) -> Bool {
        let lowercasedFilter = filter.lowercased()
        let components = lowercasedFilter.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let portSpec = String(components[0])
        let requestedProto = components.count == 2 ? String(components[1]) : nil

        if let requestedProto, requestedProto != proto.lowercased() {
            return false
        }

        if let rangeSeparator = portSpec.firstIndex(of: "-") {
            let startString = String(portSpec[..<rangeSeparator])
            let endString = String(portSpec[portSpec.index(after: rangeSeparator)...])
            guard let start = UInt16(startString), let end = UInt16(endString) else {
                return false
            }
            return port >= start && port <= end
        }

        guard let requestedPort = UInt16(portSpec) else {
            return false
        }
        return port == requestedPort
    }

    private func exposedPorts(for container: ContainerSnapshot) -> [(port: UInt16, proto: String)] {
        let declaredPorts =
            SocktainerContainerMetadata.decodeJSON(
                container.configuration.labels[SocktainerContainerMetadata.exposedPortsLabel],
                as: [String].self
            ) ?? []

        let metadataPorts = declaredPorts.compactMap { exposed -> (UInt16, String)? in
            let components = exposed.split(separator: "/", maxSplits: 1)
            guard let port = UInt16(components[0]) else {
                return nil
            }
            let proto = components.count == 2 ? String(components[1]) : "tcp"
            return (port, proto)
        }

        let publishedPorts = container.configuration.publishedPorts.map {
            ($0.containerPort, $0.proto.rawValue)
        }

        return metadataPorts + publishedPorts
    }

    private func pollUntilContainerStops(
        id: String,
        containerID: String,
        startedSessionManager: StartedContainerSessionManager?
    ) async throws -> Int64? {
        while true {
            try await Swift.Task.sleep(nanoseconds: 500_000_000)

            if let startedSessionManager,
                let exit = await startedSessionManager.exitCodeIfAvailable(containerID: containerID)
            {
                return exit
            }

            let container = try await resolveContainer(id)
            if container?.status != .running {
                return nil
            }
        }
    }

    private func dockerNetworks(for container: ContainerSnapshot) -> [String] {
        if ContainerLabelUtility.boolValue(
            container.configuration.labels[SocktainerContainerMetadata.networkDisabledLabel]
        ) == true {
            return ["none"]
        } else if container.networks.isEmpty {
            return ["none"]
        }

        return container.networks.map(\.network)
    }

    private func matchesAncestorFilter(_ filter: String, container: ContainerSnapshot) -> Bool {
        let imageReference = container.configuration.image.reference
        let imageDigest = container.configuration.image.digest

        if imageReference == filter || imageReference.hasPrefix(filter) {
            return true
        }

        if imageDigest == filter || imageDigest.hasPrefix(filter) {
            return true
        }

        if imageReference.contains("@"), let atIndex = imageReference.firstIndex(of: "@") {
            let repoName = String(imageReference[..<atIndex])
            if repoName == filter || repoName.hasPrefix(filter) {
                return true
            }
        }

        let repoDigestReference = "\(imageReference)@\(imageDigest)"
        return repoDigestReference == filter || repoDigestReference.hasPrefix(filter)
    }

    private func resolveContainer(_ reference: String) async throws -> ContainerSnapshot? {
        let sanitizedReference = ContainerNameUtility.sanitize(reference)
        do {
            let container = try await containerClient.get(id: sanitizedReference)
            return isInfrastructureContainer(container) ? nil : container
        } catch let error as ContainerizationError where error.code == .notFound {
            // Fall back to Docker-name resolution below.
        }

        let containers = try await containerClient.list().filter { !isInfrastructureContainer($0) }
        return containers.first(where: { matchesContainerReference(reference, container: $0) })
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        let allContainers = try await containerClient.list().filter { !isInfrastructureContainer($0) }
        var containers = allContainers
        if !showAll {
            containers = containers.filter { $0.status == .running }
        }

        let stoppedExitCodeByID: [String: Int64]
        if filters.keys.contains("exited") {
            stoppedExitCodeByID = await withTaskGroup(of: (String, Int64?).self) { group in
                for container in containers where container.status == .stopped {
                    group.addTask {
                        let completion = await AppleContainerExitStatusResolver.resolveCompletion(for: container)
                        return (container.id, completion?.exitCode)
                    }
                }

                var exitCodes: [String: Int64] = [:]
                for await (id, exitCode) in group {
                    if let exitCode {
                        exitCodes[id] = exitCode
                    }
                }
                return exitCodes
            }
        } else {
            stoppedExitCodeByID = [:]
        }

        for (key, values) in filters {
            switch key {
            case "status":
                containers = containers.filter { values.contains($0.status.mobyState) }
            case "exited":
                let requestedExitCodes = Set(values.compactMap(Int64.init))
                containers = containers.filter { container in
                    guard let exitCode = stoppedExitCodeByID[container.id] else {
                        return false
                    }
                    return requestedExitCodes.contains(exitCode)
                }
            case "label":
                containers = containers.filter { container in
                    let labels = userVisibleLabels(for: container)
                    return matchesLabelFilters(values, labels: labels, allowNotEquals: false)
                }
            case "name":
                containers = containers.filter { container in
                    values.contains { matchesDockerNameFilter($0, container: container) }
                }
            case "id":
                containers = containers.filter { container in
                    values.contains { filterID in
                        container.id == filterID || container.id.hasPrefix(filterID)
                    }
                }
            case "ancestor":
                containers = containers.filter { container in
                    values.contains { filter in
                        matchesAncestorFilter(filter, container: container)
                    }
                }
            case "before":
                containers = containers.filter { container in
                    for beforeId in values {
                        if let beforeContainer = allContainers.first(where: {
                            matchesContainerReference(beforeId, container: $0)
                        }) {
                            if let beforeTimestamp = AppleContainerTimestampResolver.containerCreationDate(beforeContainer),
                                let containerTimestamp = AppleContainerTimestampResolver.containerCreationDate(container)
                            {
                                return containerTimestamp < beforeTimestamp
                            }
                            return container.id < beforeContainer.id
                        }
                    }
                    return false
                }
            case "since":
                containers = containers.filter { container in
                    for sinceId in values {
                        if let sinceContainer = allContainers.first(where: {
                            matchesContainerReference(sinceId, container: $0)
                        }) {
                            if let sinceTimestamp = AppleContainerTimestampResolver.containerCreationDate(sinceContainer),
                                let containerTimestamp = AppleContainerTimestampResolver.containerCreationDate(container)
                            {
                                return containerTimestamp > sinceTimestamp
                            }
                            return container.id > sinceContainer.id
                        }
                    }
                    return false
                }
            case "health":
                containers = containers.filter { container in
                    let hasHealthcheck = container.configuration.labels[SocktainerContainerMetadata.healthcheckLabel] != nil
                    return values.contains { filterValue in
                        switch filterValue.lowercased() {
                        case "none":
                            return !hasHealthcheck
                        // NOTE: socktainer stores configured healthchecks, but the
                        // Apple backend does not surface runtime health status.
                        // Avoid fabricating state transitions here.
                        case "starting", "healthy", "unhealthy":
                            return false
                        default:
                            return false
                        }
                    }
                }
            case "volume":
                containers = containers.filter { container in
                    let volumeNames = container.configuration.mounts.compactMap { mount -> String? in
                        switch mount.type {
                        case .volume(let name, _, _, _):
                            return name
                        default:
                            return nil
                        }
                    }
                    let mountDestinations = container.configuration.mounts.map(\.destination)

                    return values.contains { filterValue in
                        volumeNames.contains(filterValue) || mountDestinations.contains(filterValue)
                    }
                }
            case "expose":
                containers = containers.filter { container in
                    let exposedPorts = exposedPorts(for: container)
                    return values.contains { filter in
                        exposedPorts.contains { exposed in
                            matchesPortFilter(port: exposed.port, proto: exposed.proto, filter: filter)
                        }
                    }
                }
            case "isolation":
                containers = containers.filter { _ in
                    values.contains { value in
                        // NOTE: Apple-backed Linux containers do not expose Docker's
                        // Windows isolation modes. Treat "default" as the only
                        // truthful match and exclude all alternate modes.
                        value.caseInsensitiveCompare("default") == .orderedSame
                    }
                }
            case "is-task":
                containers = containers.filter { container in
                    let isTask = container.configuration.labels["com.docker.swarm.task.id"] != nil
                    return values.contains(isTask ? "true" : "false")
                }
            case "network":
                containers = containers.filter { container in
                    let networkNames = dockerNetworks(for: container)
                    return values.contains { networkName in
                        networkNames.contains(networkName)
                    }
                }
            case "publish":
                containers = containers.filter { container in
                    let publishedPorts = container.configuration.publishedPorts
                    return values.contains { filter in
                        publishedPorts.contains { published in
                            matchesPortFilter(port: published.hostPort, proto: published.proto.rawValue, filter: filter)
                        }
                    }
                }
            default:
                continue
            }
        }
        return containers
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? {
        try await resolveContainer(id)
    }

    func diskUsage(id: String) async throws -> UInt64 {
        guard let container = try await resolveContainer(id) else {
            throw ClientContainerError.notFound(id: id)
        }
        return try await containerClient.diskUsage(id: container.id)
    }

    func enforceContainerRunning(container: ContainerSnapshot) throws {
        guard container.status == .running else {
            throw ClientContainerError.notRunning(id: container.id)
        }
    }

    func start(id: String, detachKeys: String?, startedSessionManager: StartedContainerSessionManager? = nil) async throws {
        guard let container = try await getContainer(id: id) else {
            throw ClientContainerError.notFound(id: id)
        }

        if container.status == .running {
            return
        }

        let stdin: FileHandle? = nil
        let stdout: FileHandle? = nil
        let stderr: FileHandle? = nil

        let stdio = [stdin, stdout, stderr]

        do {
            let process = try await containerClient.bootstrap(id: container.id, stdio: stdio)

            if let startedSessionManager {
                let session = await startedSessionManager.prepare(
                    containerID: container.id,
                    runtime: container.configuration.runtimeHandler,
                    process: process
                )
                try await session.start()
            } else {
                try await process.start()
            }
        } catch {
            // NOTE: If bootstrap fails because container is already booted,
            //       the attach handler may have already bootstrapped it
            let errorMessage = error.localizedDescription
            if errorMessage.contains("booted") || errorMessage.contains("expected to be in created state") {
                return
            }

            // Re-throw any other errors
            throw error
        }
    }

    func stop(id: String, signal: String?, timeout: Int?) async throws {
        let container = try await resolveContainer(id)
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }

        let signal = try parseSignal(signal ?? "SIGTERM")

        let options = ContainerStopOptions(timeoutInSeconds: Int32(timeout ?? 5), signal: signal)
        try await containerClient.stop(id: container.id, opts: options)
    }

    func kill(id: String, signal: String?) async throws {
        let container = try await resolveContainer(id)
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }

        guard container.status == .running else {
            throw ClientContainerError.notRunning(id: id)
        }

        let signal = try parseSignal(signal ?? "SIGKILL")

        try await containerClient.kill(id: container.id, signal: signal)
    }

    func restart(id: String, signal: String?, timeout: Int?) async throws {
        let container = try await resolveContainer(id)
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }

        if container.status == .running {
            try await stop(id: id, signal: signal, timeout: timeout)
        }

        try await start(id: id, detachKeys: nil)
    }

    func delete(id: String) async throws {
        let container = try await resolveContainer(id)
        guard let container else {
            throw ClientContainerError.notFound(id: id)
        }
        try await containerClient.delete(id: container.id)
    }

    // NOTE: For Apple Container, we'll implement a simple polling mechanism
    //       since there's no direct wait API
    func wait(id: String, condition: ContainerWaitCondition, startedSessionManager: StartedContainerSessionManager? = nil) async throws -> ContainerWaitResponse {
        var container = try await resolveContainer(id)
        guard let initialContainer = container else {
            throw ClientContainerError.notFound(id: id)
        }

        // For now, default to 0
        var exitCode: Int64 = 0

        switch condition {
        case .notRunning:
            if initialContainer.status != .running {
                if let startedSessionManager, let exit = await startedSessionManager.exitCodeIfAvailable(containerID: initialContainer.id) {
                    return ContainerWaitResponse(statusCode: exit)
                }
                return ContainerWaitResponse(statusCode: exitCode)
            }

            if let exit = try await pollUntilContainerStops(
                id: id,
                containerID: initialContainer.id,
                startedSessionManager: startedSessionManager
            ) {
                return ContainerWaitResponse(statusCode: exit)
            }

        case .nextExit:
            // Wait for next exit (only if currently running)
            if initialContainer.status == .running {
                if let exit = try await pollUntilContainerStops(
                    id: id,
                    containerID: initialContainer.id,
                    startedSessionManager: startedSessionManager
                ) {
                    return ContainerWaitResponse(statusCode: exit)
                }
            }

        case .removed:
            while true {
                try await Swift.Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                container = try await resolveContainer(id)
                guard container != nil else {
                    exitCode = 0
                    break
                }
            }
        }

        return ContainerWaitResponse(statusCode: exitCode)
    }

    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        let allContainers = try await containerClient.list().filter { !isInfrastructureContainer($0) }

        var containersToDelete: [ContainerSnapshot] = allContainers.filter { $0.status == .stopped }

        for (key, values) in filters {
            switch key {
            case "until":
                containersToDelete = containersToDelete.filter { container in
                    guard let creationDate = AppleContainerTimestampResolver.containerCreationDate(container) else {
                        // If label is not present or invalid, don't prune
                        return false
                    }

                    for timestamp in values {
                        if let untilDate = DockerBuildFilterUtility.parseUntilFilter(timestamp),
                            creationDate < untilDate
                        {
                            return true  // Prune if created before the 'until' timestamp
                        }
                    }
                    return false
                }
            case "label":
                containersToDelete = containersToDelete.filter { container in
                    let labels = userVisibleLabels(for: container)
                    return matchesLabelFilters(values, labels: labels, allowNotEquals: true)
                }
            default:
                continue
            }
        }

        // NOTE: Apple container doesn't return the size of the container, only the
        //       image descriptor size (manifest) is logged.
        //       Perhaps we should fetch the image size ourselves.
        let spaceReclaimed: Int64 = 0

        var deletedIds: [String] = []

        for container in containersToDelete {
            do {
                try await containerClient.delete(id: container.id)
                deletedIds.append(container.id)
            } catch {
                continue
            }
        }

        return (deletedContainers: deletedIds, spaceReclaimed: spaceReclaimed)
    }
}
