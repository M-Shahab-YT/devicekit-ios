import Foundation
import os

private let diagLog = OSLog(subsystem: "com.shahab.gamerecorder", category: "capture")

/// NSLog interpolates its arguments as `<private>` in the unified log, which
/// makes on-device debugging impossible (`ios syslog` shows nothing useful).
/// Log publicly instead so the PC can read the real state.
func diag(_ message: String) {
    os_log("%{public}@", log: diagLog, type: .default, message)
}
