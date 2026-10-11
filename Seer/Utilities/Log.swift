import OSLog

/// Local-only logging (unified log). Nothing is sent off the machine.
nonisolated enum Log {
    static let capture = Logger(subsystem: "Seer", category: "capture")
    static let detection = Logger(subsystem: "Seer", category: "detection")
    static let ai = Logger(subsystem: "Seer", category: "ai")
    static let ui = Logger(subsystem: "Seer", category: "ui")
}
