import UIKit
import UserNotifications

enum SteerNotifications {
    private static let enabledKey = "terminal-notifications-enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func connectionDropped(hostName: String) {
        notify(title: "Connection dropped", body: hostName)
    }

    static func terminalBell(hostName: String) {
        notify(title: hostName, body: "The remote terminal requested your attention.")
    }

    static func agentStatusChanged(hostName: String, agent: HerdrAgent, from: String?, to: String) {
        guard let title = agentTransitionTitle(agentName: agent.agent, from: from, to: to) else { return }
        // The id merges duplicate alerts when two sessions on one host poll the same pane.
        notify(
            title: title,
            body: agent.terminalTitle ?? hostName,
            id: "\(hostName)/\(agent.paneID)/\(to)"
        )
    }

    static func agentTransitionTitle(agentName: String, from: String?, to: String) -> String? {
        if to == "blocked" { return "\(agentName) needs permission" }
        if to == "done" || (to == "idle" && from == "working") { return "\(agentName) finished" }
        return nil
    }

    private static func notify(title: String, body: String, id: String = UUID().uuidString) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Shows Steer's local alerts as banners while the app is in the foreground.
final class SteerAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
