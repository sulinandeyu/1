import Foundation
import os

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "MasterCamera"

    static let camera = Logger(subsystem: subsystem, category: "Camera")
    static let storage = Logger(subsystem: subsystem, category: "Storage")
    static let imageEngine = Logger(subsystem: subsystem, category: "ImageEngine")
}

