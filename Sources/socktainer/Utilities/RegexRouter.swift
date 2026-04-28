import Foundation
import NIOConcurrencyHelpers
import Vapor

extension RoutesBuilder {
    func registerVersionedRoute<T: AsyncResponseEncodable & Sendable>(
        _ method: HTTPMethod,
        pattern: String,
        use closure: @escaping @Sendable (Request) async throws -> T
    ) throws {
        guard let app = self as? Application else {
            throw Abort(.internalServerError, reason: "Regex routes can only be registered on Application")
        }
        try app.regexRouter.register(method, pattern: pattern, use: closure)
    }
}

struct RegexRoute {
    let method: HTTPMethod
    let regex: NSRegularExpression
    let handler: @Sendable (Request, [String]) async throws -> Response
}

extension RegexRoute: Sendable {}

final class RegexRouter: Sendable {
    private static let parameterRegex = try? NSRegularExpression(pattern: #"\{([^:}]+)(?::[^}]*)?\}"#)

    private struct State: Sendable {
        var routes: [RegexRoute] = []
        var middlewareInstalled = false
    }

    private let state = NIOLockedValueBox(State())
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func register(
        _ method: HTTPMethod, pattern: String,
        handler: @escaping @Sendable (Request, [String]) async throws -> Response
    ) throws {
        let regex = try NSRegularExpression(pattern: pattern)
        state.withLockedValue { $0.routes.append(RegexRoute(method: method, regex: regex, handler: handler)) }
    }

    func register<T: AsyncResponseEncodable & Sendable>(
        _ method: HTTPMethod, pattern: String,
        use closure: @escaping @Sendable (Request) async throws -> T
    ) throws {
        // Convert Moby/Docker API pattern like "/images/{name:.*}/json" to regex
        let (regexPattern, parameterNames) = convertMobyRoutePatternToRegex(pattern)
        let regex = try NSRegularExpression(pattern: regexPattern)

        // Log registration details using instance logger
        logger.debug("RegexRouter: Registering \(method.rawValue) route - Pattern: '\(pattern)' -> Regex: '\(regexPattern)' with parameters: \(parameterNames)")

        let handler: @Sendable (Request, [String]) async throws -> Response = { req, groups in
            req.logger.debug("RegexRouter: Setting parameters from groups: \(groups) with names: \(parameterNames)")

            // Set parameters based on captured groups and their names
            for (index, paramName) in parameterNames.enumerated() {
                if index < groups.count {
                    let value = groups[index]
                    // Only set parameter if the captured value is not empty
                    if !value.isEmpty {
                        req.parameters.set(paramName, to: value)
                        req.logger.debug("RegexRouter: Set parameter '\(paramName)' = '\(value)'")

                        // Log version parameter specifically for debugging
                        if paramName == "version" {
                            req.logger.debug("RegexRouter: API version found in URL: v\(value)")
                        }
                    }
                }
            }
            let result = try await closure(req)
            return try await result.encodeResponse(for: req)
        }

        state.withLockedValue { $0.routes.append(RegexRoute(method: method, regex: regex, handler: handler)) }
    }

    private func convertMobyRoutePatternToRegex(_ pattern: String) -> (regex: String, parameterNames: [String]) {
        var regexPattern = pattern
        var parameterNames: [String] = []

        // Add version parameter as first capture group (optional)
        parameterNames.append("version")

        // Find all parameters like {paramName:.*} or {paramName}
        guard let parameterRegex = Self.parameterRegex else {
            logger.error("RegexRouter: Failed to initialize parameter regex")
            return ("^(?:/v([0-9]+\\.[0-9]+))?" + NSRegularExpression.escapedPattern(for: pattern) + "$", parameterNames)
        }
        let matches = parameterRegex.matches(in: pattern, range: NSRange(location: 0, length: pattern.count))

        // Extract parameter names in order (after version)
        for match in matches {
            let paramNameRange = match.range(at: 1)
            let paramName = (pattern as NSString).substring(with: paramNameRange)
            parameterNames.append(paramName)
        }

        // Replace all parameter patterns with capture groups
        regexPattern = parameterRegex.stringByReplacingMatches(
            in: regexPattern,
            range: NSRange(location: 0, length: regexPattern.count),
            withTemplate: "(.+)"
        )

        // Add optional version prefix: /v1.47/images/... or /images/...
        // Group 1: version (e.g., "1.47")
        // Group 2+: original parameters
        regexPattern = "^(?:/v([0-9]+\\.[0-9]+))?" + regexPattern + "$"

        return (regexPattern, parameterNames)
    }

    func installMiddleware(on app: Application) {
        let shouldInstall = state.withLockedValue { state in
            guard !state.middlewareInstalled else {
                return false
            }
            state.middlewareInstalled = true
            return true
        }
        guard shouldInstall else { return }
        app.middleware.use(RegexRoutingMiddleware(regexRouter: self))
    }

    func routesSnapshot() -> [RegexRoute] {
        state.withLockedValue { $0.routes }
    }
}

struct RegexRoutingMiddleware: Middleware {
    let regexRouter: RegexRouter

    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        let path = request.url.path
        let routes = regexRouter.routesSnapshot()

        request.logger.debug("RegexRouter: Checking path '\(path)' against \(routes.count) registered routes")

        for route in routes where route.method == request.method {
            let range = NSRange(location: 0, length: path.utf16.count)
            request.logger.debug("RegexRouter: Testing regex pattern '\(route.regex.pattern)' against path '\(path)'")

            if let match = route.regex.firstMatch(in: path, range: range) {
                let groups = (1..<match.numberOfRanges).compactMap { groupIndex in
                    let range = match.range(at: groupIndex)
                    // Check if the range is valid (NSNotFound indicates no match for optional groups)
                    guard range.location != NSNotFound else { return "" }
                    return (path as NSString).substring(with: range)
                }

                request.logger.debug("RegexRouter: MATCHED! Captured groups: \(groups)")

                let promise = request.eventLoop.makePromise(of: Response.self)
                promise.completeWithTask {
                    try await route.handler(request, groups)
                }
                return promise.futureResult
            }
        }

        request.logger.debug("RegexRouter: No regex routes matched, passing to next middleware")
        return next.respond(to: request)
    }
}

private struct RegexRouterKey: StorageKey {
    typealias Value = RegexRouter
}

extension Application {
    var regexRouter: RegexRouter {
        if let stored = self.storage[RegexRouterKey.self] {
            return stored
        }
        let router = RegexRouter(logger: self.logger)
        self.storage[RegexRouterKey.self] = router
        return router
    }

    func setRegexRouter(_ router: RegexRouter) {
        self.storage[RegexRouterKey.self] = router
    }

    func regexRouter(with logger: Logger) -> RegexRouter {
        RegexRouter(logger: logger)
    }
}
