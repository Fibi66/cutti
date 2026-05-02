import Foundation
import UIKit
import UserNotifications

/// Wraps a long-running export in a UIApplication background task and
/// posts a local notification on completion when the app is NOT in the
/// foreground. Gives the user the "ding, your video is ready" affordance
/// they expect from any modern editor: start the render, switch to
/// WeChat, come back when the notification arrives.
///
/// Usage:
/// ```
/// let coordinator = BackgroundExportCoordinator()
/// coordinator.begin()
/// // ... run export ...
/// coordinator.finish(success: true, title: "导出完成", body: "视频已保存到相册")
/// ```
///
/// `finish` is safe to call multiple times (idempotent); the second
/// call is a no-op. `begin` requests notification permission lazily so
/// first-time users only see the OS prompt the first time they tap
/// export, not on app launch.
@MainActor
final class BackgroundExportCoordinator {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var finished = false

    func begin() {
        // Ask for notification permission on first use. We don't block
        // on the answer — if the user says no, the in-app progress
        // sheet still works; we just won't fire a system banner.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }

        taskID = UIApplication.shared.beginBackgroundTask(withName: "cutti.export") { [weak self] in
            // iOS is about to expire our background time. End the
            // task cleanly so we don't get killed with prejudice.
            guard let self else { return }
            Task { @MainActor in self.endTask() }
        }
    }

    /// Called from the export completion handler. If the app is
    /// backgrounded/inactive at this moment, fires a local notification;
    /// otherwise the in-app sheet's own "完成" state is enough.
    func finish(success: Bool, title: String, body: String) {
        guard !finished else { return }
        finished = true

        let appActive = UIApplication.shared.applicationState == .active
        if !appActive {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = success ? .default : .defaultCritical
            let req = UNNotificationRequest(
                identifier: "cutti.export.\(UUID().uuidString)",
                content: content,
                // nil trigger => deliver immediately
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }

        endTask()
    }

    private func endTask() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
