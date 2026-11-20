import Foundation
import UserNotifications
import BurnbarCore

/// Posts one notification per window when usage crosses 80 % and again at 95 %.
@MainActor
final class Notifier {
    private let defaults = UserDefaults.standard
    private let sentKey = "notificationsSent"
    /// UNUserNotificationCenter traps when the process isn't inside an app bundle.
    private let available = Bundle.main.bundleIdentifier != nil

    var enabled: Bool {
        get { defaults.object(forKey: "notify") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notify"); if newValue { requestAuthorization() } }
    }

    /// What macOS currently allows; refreshed at launch and whenever the menu opens.
    private(set) var authorized: Bool?

    func refreshAuthorizationStatus() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Log.app.notice("notification authorizationStatus=\(settings.authorizationStatus.rawValue)")
            Task { @MainActor in self.authorized = ok }
        }
    }

    func requestAuthorization() {
        guard available, enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.app.notice("notification authorization granted=\(granted) error=\(String(describing: error), privacy: .public)")
            Task { @MainActor in self.authorized = granted }
        }
    }

    func check(_ u: Usage) {
        guard available, enabled else { return }
        var sent = defaults.stringArray(forKey: sentKey) ?? []
        for (tag, name, w) in [("s", "Session", u.session), ("w", "Weekly", u.week)] {
            guard let reset = w.resetsAt else { continue }
            // Highest threshold crossed only; mark lower ones too so they don't follow.
            let crossed = [80.0, 95.0].filter { w.percent >= $0 }
            guard let top = crossed.last else { continue }
            let key = { (t: Double) in "\(tag)-\(Int(t))-\(Int(reset.timeIntervalSince1970))" }
            guard !sent.contains(key(top)) else { continue }
            crossed.forEach { sent.append(key($0)) }

            let content = UNMutableNotificationContent()
            content.title = "\(name) limit at \(Format.percent(w.percent))"
            content.body = "Resets \(Format.resetTime(reset, now: Date())) (in \(Format.countdown(to: reset, from: Date())))."
            content.sound = top >= 95 ? .default : nil
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key(top), content: content, trigger: nil))
            Log.app.notice("notified \(key(top), privacy: .public)")
        }
        defaults.set(Array(sent.suffix(40)), forKey: sentKey)
    }
}
