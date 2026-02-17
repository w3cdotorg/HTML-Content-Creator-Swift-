import Foundation

enum LegacyDateFormatter {
    private static let fullDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let yyyymmddFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let hhmmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HHmm"
        return formatter
    }()

    static func fullDateTimeString(from date: Date) -> String {
        fullDateTimeFormatter.string(from: date)
    }

    static func parseFullDateTime(_ rawValue: String) -> Date? {
        fullDateTimeFormatter.date(from: rawValue)
    }

    static func yyyymmddString(from date: Date) -> String {
        yyyymmddFormatter.string(from: date)
    }

    static func hhmmString(from date: Date) -> String {
        hhmmFormatter.string(from: date)
    }
}
