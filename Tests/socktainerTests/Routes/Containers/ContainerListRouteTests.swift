import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private struct MockImageClient: ClientImageProtocol {
    func list(includeSystemImages: Bool) async throws -> [ClientImage] { [] }
    func delete(id: String, force: Bool) async throws {}
    func pull(image: String, tag: String?, platform: Platform, logger: Logger) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    func push(
        imageName: String,
        tag: String?,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        logger: Logger
    ) async throws -> AsyncThrowingStream<ClientImagePushEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    func prune(filters: [String: [String]], logger: Logger) async throws -> (deletedImages: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
    func load(
        tarballPath: URL,
        platform: Platform?,
        appleContainerAppSupportUrl: URL,
        importMessage: String?,
        importChanges: [String],
        logger: Logger
    ) async throws -> [String] {
        []
    }
    func save(references: [String], platform: Platform?, appleContainerAppSupportUrl: URL, logger: Logger) async throws -> URL {
        URL(fileURLWithPath: "/tmp/mock.tar")
    }
}

private final class MockContainerClient: @unchecked Sendable, ClientContainerProtocol {
    private struct State {
        var lastShowAll: Bool?
        var lastFilters: [String: [String]]?
        var snapshots: [ContainerSnapshot]
    }

    private let state: NIOLockedValueBox<State>

    init(snapshots: [ContainerSnapshot] = []) {
        state = NIOLockedValueBox(State(lastShowAll: nil, lastFilters: nil, snapshots: snapshots))
    }

    var lastShowAll: Bool? {
        state.withLockedValue { $0.lastShowAll }
    }

    var lastFilters: [String: [String]]? {
        state.withLockedValue { $0.lastFilters }
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        state.withLockedValue {
            $0.lastShowAll = showAll
            $0.lastFilters = filters
        }
        return state.withLockedValue { $0.snapshots }
    }

    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func diskUsage(id: String) async throws -> UInt64 { 0 }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?, startedSessionManager: StartedContainerSessionManager?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition, startedSessionManager: StartedContainerSessionManager?) async throws -> ContainerWaitResponse {
        ContainerWaitResponse(statusCode: 0)
    }

    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

@Suite
struct ContainerListRouteTests {
    private func stoppedSnapshot(id: String) -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:test",
            size: 123
        )
        let image = ImageDescription(reference: "docker.io/library/alpine:3", descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "sh",
            arguments: ["-c", "exit 0"],
            environment: ["PATH=/usr/bin:/bin"]
        )
        let config = ContainerConfiguration(id: id, image: image, process: process)
        return ContainerSnapshot(configuration: config, status: .stopped, networks: [])
    }

    private func withRoute(
        client: MockContainerClient = MockContainerClient(),
        _ test: @escaping (Application, MockContainerClient) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[StoppedContainerAttachSessionManagerKey.self] = StoppedContainerAttachSessionManager()
            try app.register(collection: ContainerListRoute(client: client, imageClient: MockImageClient()))
            try await test(app, client)
        }
    }

    @Test
    func invalidExitedFilterReturnsBadRequest() async throws {
        try await withRoute { app, _ in
            try await app.testing().test(
                .GET,
                "/containers/json?filters=%7B%22exited%22%3A%7B%22foo%22%3Atrue%7D%7D"
            ) { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Invalid exited filter value: foo"))
            }
        }
    }

    @Test
    func acceptsDockerStatusFilterSet() async throws {
        try await withRoute { app, client in
            try await app.testing().test(
                .GET,
                "/containers/json?all=1&filters=%7B%22status%22%3A%7B%22paused%22%3Atrue%2C%22dead%22%3Atrue%7D%7D"
            ) { res async in
                #expect(res.status == .ok)
            }

            let recordedShowAll = client.lastShowAll
            let recordedFilters = client.lastFilters
            #expect(recordedShowAll == true)
            #expect(Set(recordedFilters?["status"] ?? []) == Set(["paused", "dead"]))
        }
    }

    @Test
    func exitedFilterUsesAttachSessionCompletions() async throws {
        let client = MockContainerClient(snapshots: [stoppedSnapshot(id: "test-exit-zero")])

        try await withRoute(client: client) { app, _ in
            let attachManager = try #require(app.storage[StoppedContainerAttachSessionManagerKey.self])
            await attachManager.markCompleted(containerID: "test-exit-zero", exitCode: 0)

            try await app.testing().test(
                .GET,
                "/containers/json?all=1&filters=%7B%22exited%22%3A%7B%220%22%3Atrue%7D%7D"
            ) { res async in
                #expect(res.status == .ok)
                let containers = try? res.content.decode([ContainerSummary].self)
                #expect(containers != nil)
                #expect(containers?.count == 1)
                #expect(containers?.first?.id == "test-exit-zero")
                #expect(containers?.first?.status?.contains("Exited (0)") == true)
            }
        }
    }
}
