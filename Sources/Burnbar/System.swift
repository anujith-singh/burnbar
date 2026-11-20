import AppKit
import IOKit.ps
import os

enum Log {
    static let app = Logger(subsystem: "com.burnbar.Burnbar", category: "app")
}

enum PowerSource {
    /// True on AC. Desktops (no battery) report AC as well.
    static func isOnAC() -> Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

enum ScreenLock {
    /// Lock state at launch; afterwards it's tracked with the screenIsLocked/Unlocked notifications.
    static func isLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}
