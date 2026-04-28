import Foundation
import NIOConcurrencyHelpers
import NIOCore

// Safe as @unchecked Sendable because all mutable state is serialized through
// NIOLockedValueBox and the class only exposes atomic state transitions.
final class DockerUpgradeWriteState: @unchecked Sendable {
    private struct State {
        var pendingWrites = 0
        var closeRequested = false
        var closed = false
    }

    private let state = NIOLockedValueBox(State())

    func enqueueWrite() -> Bool {
        state.withLockedValue { state in
            guard !state.closed else {
                return false
            }
            state.pendingWrites += 1
            return true
        }
    }

    func completeWrite(channel: Channel) {
        let shouldClose = state.withLockedValue { state in
            state.pendingWrites = max(0, state.pendingWrites - 1)
            guard state.closeRequested, state.pendingWrites == 0, !state.closed else {
                return false
            }
            state.closed = true
            return true
        }

        if shouldClose {
            channel.close(promise: nil)
        }
    }

    func requestClose(channel: Channel) {
        let shouldClose = state.withLockedValue { state in
            state.closeRequested = true
            guard state.pendingWrites == 0, !state.closed else {
                return false
            }
            state.closed = true
            return true
        }

        if shouldClose {
            channel.close(promise: nil)
        }
    }

    func hasPendingWrites() -> Bool {
        state.withLockedValue { $0.pendingWrites > 0 }
    }
}

// Safe as @unchecked Sendable because all mutable state is serialized through
// NIOLockedValueBox and reads/writes do not escape without synchronization.
final class DockerUpgradeCloseState: @unchecked Sendable {
    private struct State {
        var eofStreams = 0
        var processExited = false
    }

    private let state = NIOLockedValueBox(State())
    private let configuredStreams: Int

    init(configuredStreams: Int) {
        self.configuredStreams = configuredStreams
    }

    func recordEOF() {
        state.withLockedValue { $0.eofStreams += 1 }
    }

    func markProcessExited() {
        state.withLockedValue { $0.processExited = true }
    }

    func canClose(pendingWrites: Bool) -> Bool {
        state.withLockedValue { state in
            state.processExited && (configuredStreams == 0 || state.eofStreams >= configuredStreams) && !pendingWrites
        }
    }
}

enum DockerStreamRuntime {
    static func makeOutputBuffer(
        allocator: ByteBufferAllocator,
        data: Data,
        streamType: DockerStreamFrame.StreamType,
        tty: Bool
    ) -> ByteBuffer {
        let capacity = min(data.count + (tty ? 0 : 8), 65536)
        var buffer = allocator.buffer(capacity: capacity)
        if tty {
            buffer.writeBytes(data)
        } else {
            buffer.writeDockerFrame(streamType: streamType, data: data, ttyMode: false)
        }
        return buffer
    }

    static func writeToStdin(_ writer: FileHandle, data: Data) throws {
        try writer.write(contentsOf: data)
    }

    static func installReadabilityHandler(
        on handle: FileHandle?,
        streamType: DockerStreamFrame.StreamType,
        tty: Bool,
        allocator: ByteBufferAllocator,
        onChunk: @escaping @Sendable (ByteBuffer) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        handle?.readabilityHandler = { readHandle in
            let data = readHandle.availableData
            if data.isEmpty {
                readHandle.readabilityHandler = nil
                onEOF()
                return
            }

            let buffer = makeOutputBuffer(
                allocator: allocator,
                data: data,
                streamType: streamType,
                tty: tty
            )
            onChunk(buffer)
        }
    }

    static func scheduleChannelWrite(
        _ outputBuffer: ByteBuffer,
        on channel: Channel,
        writeState: DockerUpgradeWriteState
    ) {
        channel.eventLoop.execute {
            guard writeState.enqueueWrite() else {
                return
            }
            channel.writeAndFlush(outputBuffer).whenComplete { _ in
                writeState.completeWrite(channel: channel)
            }
        }
    }

    static func requestCloseIfPossible(
        channel: Channel,
        writeState: DockerUpgradeWriteState,
        closeState: DockerUpgradeCloseState
    ) {
        if closeState.canClose(pendingWrites: writeState.hasPendingWrites()) {
            _ = channel.eventLoop.submit {
                writeState.requestClose(channel: channel)
            }
        }
    }

    static func installUpgradedReadabilityHandler(
        on handle: FileHandle?,
        streamType: DockerStreamFrame.StreamType,
        tty: Bool,
        channel: Channel,
        writeState: DockerUpgradeWriteState,
        closeState: DockerUpgradeCloseState,
        onEOF: @escaping @Sendable () -> Void
    ) {
        installReadabilityHandler(
            on: handle,
            streamType: streamType,
            tty: tty,
            allocator: channel.allocator,
            onChunk: { outputBuffer in
                scheduleChannelWrite(outputBuffer, on: channel, writeState: writeState)
            },
            onEOF: {
                onEOF()
                closeState.recordEOF()
                requestCloseIfPossible(channel: channel, writeState: writeState, closeState: closeState)
            }
        )
    }

    static func drainTrailingData(
        from handle: FileHandle?,
        streamType: DockerStreamFrame.StreamType,
        tty: Bool
    ) -> (buffer: ByteBuffer?, drained: Bool) {
        guard let handle else {
            return (nil, false)
        }

        handle.readabilityHandler = nil
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else {
            return (nil, true)
        }

        let capacity = min(data.count + (tty ? 0 : 8), 65536)
        var buffer = sharedAllocator.buffer(capacity: capacity)
        buffer.writeDockerFrame(streamType: streamType, data: data, ttyMode: tty)
        return (buffer, true)
    }

    static func emitTrailingOutput(
        stdout: FileHandle?,
        stderr: FileHandle?,
        tty: Bool,
        emit: @escaping @Sendable (ByteBuffer) -> Void
    ) {
        let stdoutDrain = drainTrailingData(from: stdout, streamType: .stdout, tty: tty)
        if let trailing = stdoutDrain.buffer {
            emit(trailing)
        }

        let stderrDrain = drainTrailingData(from: stderr, streamType: .stderr, tty: tty)
        if let trailing = stderrDrain.buffer {
            emit(trailing)
        }
    }

    static func forwardBody<S: AsyncSequence>(_ body: S, to writer: FileHandle) async
    where S.Element == ByteBuffer {
        defer {
            try? writer.close()
        }

        do {
            for try await var buf in body {
                if let data = buf.readData(length: buf.readableBytes) {
                    try writeToStdin(writer, data: data)
                }
            }
        } catch {
        }
    }

    static func emitTrailingOutputToChannel(
        stdout: FileHandle?,
        stderr: FileHandle?,
        tty: Bool,
        channel: Channel,
        closeState: DockerUpgradeCloseState
    ) async {
        let stdoutDrain = drainTrailingData(from: stdout, streamType: .stdout, tty: tty)
        if stdoutDrain.drained {
            closeState.recordEOF()
        }
        if let trailing = stdoutDrain.buffer {
            try? await channel.writeAndFlush(trailing).get()
        }

        let stderrDrain = drainTrailingData(from: stderr, streamType: .stderr, tty: tty)
        if stderrDrain.drained {
            closeState.recordEOF()
        }
        if let trailing = stderrDrain.buffer {
            try? await channel.writeAndFlush(trailing).get()
        }
    }
}
