import NIOCore
import NIOHTTP1
import Vapor

enum DockerPlainStreamingResponse {
    static func create(
        request: Request,
        ttyEnabled: Bool,
        nonTTYContentType: String = "application/vnd.docker.multiplexed-stream",
        streamHandler: @escaping @Sendable (AsyncThrowingStream<ByteBuffer, Error>.Continuation) async throws -> Void
    ) -> Response {

        let connectionHeader = request.headers.first(name: "Connection")?.lowercased()
        let upgradeHeader = request.headers.first(name: "Upgrade")?.lowercased()
        let shouldUpgrade = connectionHeader?.contains("upgrade") == true && upgradeHeader == "tcp"

        let contentType = ttyEnabled ? "application/vnd.docker.raw-stream" : nonTTYContentType

        var headers: HTTPHeaders = [:]
        if shouldUpgrade {
            headers.add(name: "Connection", value: "Upgrade")
            headers.add(name: "Upgrade", value: "tcp")
        } else {
            headers.add(name: "Content-Type", value: contentType)
        }

        let body = Response.Body(stream: { writer in
            let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()

            Swift.Task.detached {
                do {
                    try await streamHandler(continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            Swift.Task.detached {
                do {
                    for try await buffer in stream {
                        _ = writer.write(.buffer(buffer))
                    }
                    _ = writer.write(.end)
                } catch {
                    _ = writer.write(.end)
                }
            }
        })

        let status: HTTPStatus = shouldUpgrade ? .switchingProtocols : .ok
        return Response(status: status, headers: headers, body: body)
    }
}
