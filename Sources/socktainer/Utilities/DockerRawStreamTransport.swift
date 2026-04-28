import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import Vapor

public struct DockerRawStreamUpgrader: Upgrader, Sendable {
    let ttyEnabled: Bool
    let streamHandler: @Sendable (Channel, DockerRawStreamHandler) async throws -> Void

    public init(ttyEnabled: Bool, streamHandler: @escaping @Sendable (Channel, DockerRawStreamHandler) async throws -> Void) {
        self.ttyEnabled = ttyEnabled
        self.streamHandler = streamHandler
    }

    public func applyUpgrade(req: Request, res: Response) -> HTTPServerProtocolUpgrader {
        DockerRawStreamProtocolUpgrader(
            ttyEnabled: ttyEnabled,
            streamHandler: streamHandler
        )
    }
}

private struct DockerRawStreamProtocolUpgrader: HTTPServerProtocolUpgrader {
    let ttyEnabled: Bool
    let streamHandler: @Sendable (Channel, DockerRawStreamHandler) async throws -> Void

    var supportedProtocol: String { "tcp" }
    var requiredUpgradeHeaders: [String] { ["upgrade"] }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        var headers = HTTPHeaders()
        let contentType = ttyEnabled ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Connection", value: "Upgrade")
        headers.add(name: "Upgrade", value: "tcp")
        return channel.eventLoop.makeSucceededFuture(headers)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        let rawStreamHandler = DockerRawStreamHandler()

        let channel = context.channel
        let eventLoop = context.eventLoop

        return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap { _ in
            channel.pipeline.addHandler(rawStreamHandler)
        }.flatMap { _ in
            _ = Swift.Task.detached { [streamHandler] in
                do {
                    try await streamHandler(channel, rawStreamHandler)
                } catch {
                    eventLoop.execute {
                        channel.close(promise: nil)
                    }
                }
            }

            return eventLoop.makeSucceededVoidFuture()
        }
    }
}

public final class DockerRawStreamHandler: ChannelInboundHandler, Sendable {
    public typealias InboundIn = ByteBuffer

    private struct StdinState {
        var writer: FileHandle?
        var bufferedData: [Data] = []
        var inputClosed = false
    }

    private let stdinState = NIOLockedValueBox(StdinState())
    private let closeStdinOnChannelInactive = NIOLockedValueBox(true)

    init() {}

    public func channelActive(context: ChannelHandlerContext) {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let data = buffer.getData(at: 0, length: buffer.readableBytes) else {
            return
        }

        do {
            try self.stdinState.withLockedValue { state in
                guard let writer = state.writer else {
                    state.bufferedData.append(data)
                    return
                }
                try DockerStreamRuntime.writeToStdin(writer, data: data)
            }
        } catch {
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            stdinState.withLockedValue { state in
                state.inputClosed = true
                if let writer = state.writer {
                    try? writer.close()
                    state.writer = nil
                }
            }
            return
        }

        context.fireUserInboundEventTriggered(event)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        let shouldClose = closeStdinOnChannelInactive.withLockedValue { $0 }
        stdinState.withLockedValue { state in
            guard shouldClose else {
                return
            }
            try? state.writer?.close()
            state.writer = nil
        }
    }

    public func setStdinWriter(_ writer: FileHandle?) {
        stdinState.withLockedValue { state in
            state.writer = writer
            guard let writer else {
                state.bufferedData.removeAll(keepingCapacity: false)
                state.inputClosed = false
                return
            }

            for data in state.bufferedData {
                try? DockerStreamRuntime.writeToStdin(writer, data: data)
            }
            state.bufferedData.removeAll(keepingCapacity: false)
        }
    }

    public func setCloseStdinOnInactive(_ enabled: Bool) {
        closeStdinOnChannelInactive.withLockedValue { $0 = enabled }
    }

    public func inputClosedObserved() -> Bool {
        stdinState.withLockedValue { $0.inputClosed }
    }
}

extension Response {
    static func dockerRawStreamUpgrade(
        ttyEnabled: Bool,
        streamHandler: @escaping @Sendable (Channel, DockerRawStreamHandler) async throws -> Void
    ) -> Response {
        let upgrader = DockerRawStreamUpgrader(
            ttyEnabled: ttyEnabled,
            streamHandler: streamHandler
        )

        let response = Response(status: .switchingProtocols)
        response.upgrader = upgrader

        return response
    }
}
