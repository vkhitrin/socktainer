import Foundation
import Testing
import Vapor

@testable import socktainer

@Suite class SocketUtilityTests {
    private var app: Application

    init() async throws {
        app = try await Application.make(.testing)
    }

    @Test
    func testPrepareUnixSocketThrowsWhenHomeIsMissing() async throws {
        do {
            try prepareUnixSocket(for: app, homeDirectory: nil)
            Issue.record("Expected prepareUnixSocket to throw when homeDirectory is nil")
        } catch {
            // Expected error, test passes
        }

        // Explicitly shutdown at the end of the test
        try await app.asyncShutdown()
    }

    @Test
    func testPrepareUnixSocketCreatesDirectoryAndRemovesOldSocket() async throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let socketDir = tempHome.appendingPathComponent(".socktainer")
        let socketPath = socketDir.appendingPathComponent("container.sock")

        try fileManager.createDirectory(at: socketDir, withIntermediateDirectories: true)
        fileManager.createFile(atPath: socketPath.path, contents: Data())

        try prepareUnixSocket(for: app, homeDirectory: tempHome.path)

        #expect(fileManager.fileExists(atPath: socketDir.path))
        #expect(!fileManager.fileExists(atPath: socketPath.path))
        #expect(app.http.server.configuration.address == .unixDomainSocket(path: socketPath.path))

        try? fileManager.removeItem(at: tempHome)

        // Explicitly shutdown at the end of the test
        try await app.asyncShutdown()

    }
}
