import OSLog

enum AppLogger {
    static let subsystem = "com.swiftgpt.htmlcontentcreator"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let io = Logger(subsystem: subsystem, category: "io")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let deck = Logger(subsystem: subsystem, category: "deck")
}
