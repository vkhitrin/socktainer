import Vapor

struct ContainerSignalUtility {
    static func validatedSignal(_ signal: String?, action: String) throws -> String? {
        guard let signal, !signal.isEmpty else {
            return nil
        }

        do {
            _ = try parseSignal(signal)
        } catch {
            throw Abort(.badRequest, reason: "invalid \(action) signal: \(signal)")
        }

        return signal
    }

    static func validatedTimeout(
        _ timeout: Int?,
        action: String
    ) throws -> Int? {
        if let timeout, timeout < 0 {
            throw Abort(.badRequest, reason: "\(action) timeout must be non-negative")
        }
        return timeout
    }
}
