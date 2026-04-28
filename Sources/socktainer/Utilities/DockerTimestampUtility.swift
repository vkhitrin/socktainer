import Foundation

enum DockerTimestampUtility {
    static func pathStatTimestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
