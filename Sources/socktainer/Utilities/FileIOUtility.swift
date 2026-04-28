import Foundation

enum FileIOUtility {
    static func readData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }
}
