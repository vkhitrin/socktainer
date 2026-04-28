import Foundation
import Vapor

enum RequestBodyFileUtility {
    static func writeRequestBody(
        _ request: Request,
        to fileURL: URL,
        failureReason: String,
        emptyBodyReason: String = "Request body is required"
    ) async throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        var fileHandle: FileHandle?
        var totalBytesWritten = 0

        do {
            fileHandle = try FileHandle(forWritingTo: fileURL)

            if let bodyData = request.body.data {
                let data = Data(buffer: bodyData)
                try fileHandle?.write(contentsOf: data)
                totalBytesWritten = data.count
            } else {
                for try await var chunk in request.body {
                    guard let data = chunk.readData(length: chunk.readableBytes) else {
                        continue
                    }
                    try fileHandle?.write(contentsOf: data)
                    totalBytesWritten += data.count
                }
            }

            try fileHandle?.synchronize()
            try fileHandle?.close()
            fileHandle = nil
        } catch {
            try? fileHandle?.close()
            throw Abort(.badRequest, reason: "\(failureReason): \(error.localizedDescription)")
        }

        guard totalBytesWritten > 0 else {
            throw Abort(.badRequest, reason: emptyBodyReason)
        }
    }
}
