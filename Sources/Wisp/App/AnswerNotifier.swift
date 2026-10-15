import Foundation
import UserNotifications
import WispCore

/// "Ask and walk away": when an answer finishes while the panel is hidden, a notification shows its
/// first lines, and clicking it brings the panel back.
@MainActor
final class AnswerNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let onOpen: @MainActor () -> Void

    init(onOpen: @escaping @MainActor () -> Void) {
        self.onOpen = onOpen
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(_ turn: Turn) {
        let title = TextPreview.line(turn.query, limit: 70)
        let body = TextPreview.line(turn.answer, limit: 180)
        Log.info("answer finished in the background; notifying")
        Task { await Self.post(id: turn.id.uuidString, title: title, body: body) }
    }

    /// Off the main actor: UserNotifications answers on its own queues.
    private nonisolated static func post(id: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        do {
            // Asks for permission the first time; macOS remembers the answer.
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                return Log.info("notification skipped: not allowed in System Settings")
            }
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            Log.info("notified")
        } catch {
            Log.info("notification failed: \(error.localizedDescription)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in onOpen() }
        completionHandler()
    }

    /// Wisp may be frontmost (panel open) when a notification arrives; show it anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
