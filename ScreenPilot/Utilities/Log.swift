import OSLog

/// Local-only logging (unified log). Nothing is sent off the machine.
nonisolated enum Log {
    static let capture = Logger(subsystem: "ScreenPilot", category: "capture")
    static let detection = Logger(subsystem: "ScreenPilot", category: "detection")
    static let ai = Logger(subsystem: "ScreenPilot", category: "ai")
    static let ui = Logger(subsystem: "ScreenPilot", category: "ui")
}
