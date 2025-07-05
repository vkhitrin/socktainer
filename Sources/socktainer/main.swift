import Vapor
import ContainerClient
import Foundation

// Docker-compatible summary struct
struct DockerContainerSummary: Content {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let Status: String
}

// Query parameters (e.g. /containers/json?all=true)
struct ContainerListQuery: Content {
    let all: Bool?
}

func routes(_ app: Application) throws {
    app.get("containers", "json") { req async throws -> [DockerContainerSummary] in
        let query = try req.query.decode(ContainerListQuery.self)
        let showAll = query.all ?? false

        // Use top-level function instead of ClientContainer instance
        let containers = try await ClientContainer.list()

        return containers.map { container in
            DockerContainerSummary(
                Id: container.id,
                Names: ["/" + container.id],
                Image: container.configuration.image.reference,
                ImageID: container.configuration.image.digest,
                Status: container.status.rawValue,
            )
        }
    }
}

@main
struct Main {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        // Create the app asynchronously
        let app = try await Application.make(env)

        // Get $HOME environment variable
        guard let homeDir = ProcessInfo.processInfo.environment["HOME"] else {
            fatalError("HOME environment variable not found")
        }
let fileManager = FileManager.default
let socketDirectory = "\(homeDir)/.socktainer"
let socketPath = "\(socketDirectory)/container.sock"

// Create directory if it doesn't exist
if !fileManager.fileExists(atPath: socketDirectory) {
    try fileManager.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true)
}

// Remove existing socket file if any
if fileManager.fileExists(atPath: socketPath) {
    try fileManager.removeItem(atPath: socketPath)
}

        // Add shutdown hook to remove socket file on exit
        app.lifecycle.use(ShutdownHandler(socketPath: socketPath))
      
        // Configure the server to listen on the Unix domain socket
        app.http.server.configuration.hostname = ""  // no hostname needed for unix socket
        app.http.server.configuration.port = 0         // no TCP port
        app.http.server.configuration.address = .unixDomainSocket(path: socketPath)

        try routes(app)

        try await app.execute()
    }
}


// Define a lifecycle handler for cleanup
struct ShutdownHandler: LifecycleHandler {
    let socketPath: String

    func shutdown(_ application: Application) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: socketPath) {
            do {
                try fileManager.removeItem(atPath: socketPath)
                application.logger.info("Removed socket file at shutdown: \(socketPath)")
            } catch {
                application.logger.error("Failed to remove socket file at shutdown: \(error.localizedDescription)")
            }
        }
    }
}