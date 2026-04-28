import Foundation
import Vapor

enum RegistryAuthUtility {
    struct Credentials {
        let server: String
        let username: String
        let password: String
    }

    private struct RegistryAuthHeader: Decodable {
        let username: String?
        let password: String?
        let serveraddress: String?
        let auth: String?
    }

    private struct RegistryConfigEntry: Decodable {
        let username: String?
        let password: String?
        let auth: String?
        let serveraddress: String?
    }

    static func decodeBase64MaybeURLSafe(_ value: String) -> Data? {
        if let decoded = Data(base64Encoded: value) {
            return decoded
        }

        let normalized =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: padding)
        return Data(base64Encoded: padded)
    }

    static func parseSingleHeader(_ header: String?) throws -> Credentials? {
        guard let header, !header.isEmpty else {
            return nil
        }
        guard let decoded = decodeBase64MaybeURLSafe(header) else {
            throw Abort(.badRequest, reason: "Invalid X-Registry-Auth header")
        }

        let auth = try JSONDecoder().decode(RegistryAuthHeader.self, from: decoded)
        let username = auth.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = auth.password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = auth.serveraddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let packedAuth = auth.auth?.trimmingCharacters(in: .whitespacesAndNewlines)

        if username == nil || username?.isEmpty == true,
            password == nil || password?.isEmpty == true,
            server == nil || server?.isEmpty == true,
            packedAuth == nil || packedAuth?.isEmpty == true
        {
            // Docker CLI sends an empty JSON object for anonymous registry
            // operations. Treat that as "no credentials supplied".
            return nil
        }

        if let username, let password, let server,
            !username.isEmpty, !password.isEmpty, !server.isEmpty
        {
            return Credentials(server: server, username: username, password: password)
        }

        if let packedAuth,
            let packedData = decodeBase64MaybeURLSafe(packedAuth),
            let packedString = String(data: packedData, encoding: .utf8),
            let separator = packedString.firstIndex(of: ":")
        {
            let username = String(packedString[..<separator])
            let password = String(packedString[packedString.index(after: separator)...])
            let server = server ?? "https://index.docker.io/v1/"
            if !username.isEmpty, !password.isEmpty {
                return Credentials(server: server, username: username, password: password)
            }
        }

        throw Abort(.badRequest, reason: "Invalid X-Registry-Auth header")
    }

    static func decodeRegistryConfigHeader(_ headerValue: String?) -> [Credentials] {
        guard let headerValue, !headerValue.isEmpty else {
            return []
        }

        // Match Docker's permissive handling here: malformed auth config is
        // ignored instead of failing the whole build request.
        guard let decodedData = decodeBase64MaybeURLSafe(headerValue) else {
            return []
        }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any] else {
            return []
        }

        let decoder = JSONDecoder()
        var results: [Credentials] = []
        results.reserveCapacity(jsonObject.count)

        for (server, rawValue) in jsonObject {
            guard let entryData = try? JSONSerialization.data(withJSONObject: rawValue),
                let entry = try? decoder.decode(RegistryConfigEntry.self, from: entryData)
            else {
                continue
            }

            let resolvedServer = entry.serveraddress ?? server
            if let username = entry.username, let password = entry.password,
                !username.isEmpty, !password.isEmpty
            {
                results.append(Credentials(server: resolvedServer, username: username, password: password))
                continue
            }

            if let auth = entry.auth,
                let decodedAuth = decodeBase64MaybeURLSafe(auth),
                let authString = String(data: decodedAuth, encoding: .utf8),
                let separator = authString.firstIndex(of: ":")
            {
                let username = String(authString[..<separator])
                let password = String(authString[authString.index(after: separator)...])
                if !username.isEmpty, !password.isEmpty {
                    results.append(Credentials(server: resolvedServer, username: username, password: password))
                }
            }
        }

        return results
    }
}
