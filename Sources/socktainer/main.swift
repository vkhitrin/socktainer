import Foundation
import Vapor

// Detect environment and set up logging
var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

// Create and configure the Vapor application
let app = try await Application.make(env)
try prepareUnixSocket(for: app, homeDirectory: ProcessInfo.processInfo.environment["HOME"])
try await configure(app)

// Start the app
try await app.execute()
