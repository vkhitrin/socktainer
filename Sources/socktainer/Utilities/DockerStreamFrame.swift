import Foundation
import NIOCore

public let sharedAllocator = ByteBufferAllocator()

public struct DockerStreamFrame {
    public enum StreamType: UInt8, Sendable {
        case stdin = 0
        case stdout = 1
        case stderr = 2
    }

    public let streamType: StreamType
    public let data: Data

    public init(streamType: StreamType, data: Data) {
        self.streamType = streamType
        self.data = data
    }
}

extension ByteBuffer {
    mutating func writeDockerFrame(streamType: DockerStreamFrame.StreamType, data: Data, ttyMode: Bool) {
        if ttyMode {
            writeBytes(data)
        } else {
            writeInteger(streamType.rawValue, as: UInt8.self)
            writeInteger(UInt8(0), as: UInt8.self)
            writeInteger(UInt8(0), as: UInt8.self)
            writeInteger(UInt8(0), as: UInt8.self)
            writeInteger(UInt32(data.count), endianness: .big, as: UInt32.self)
            writeBytes(data)
        }
    }
}
