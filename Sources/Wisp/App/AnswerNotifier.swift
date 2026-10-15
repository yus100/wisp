import Foundation
import UserNotifications
import WispCore

/// "Ask and walk away": when an answer finishes while the panel is hidden, a notification shows its
/// first lines, and clicking it brings the panel back.
@MainActor
final class AnswerNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let onOpen: @MainActor () -> Void
    private var center: UNUserNotificationCenter { .current() }

    init(onOpen: @escaping @MainActor () -> Void) {
        self.onOpen = onOpen
        super.init()
        center.delegate = self
    }

    func notify(_ turn: Turn) {
        let content = UNMutableNotificationContent()
        content.title = TextPreview.line(turn.query, limit: 70)
        content.body = TextPreview.line(turn.answer, limit: 180)
        let request = UNNotificationRequest(identifier: turn.id.uuidString, content: content, trigger: nil)
        // Asks for permission the first time; macOS remembers the answer.
        center.requestAuthorization(options: [.alert, .sound]) { [center] granted, _ in
            guard granted else { return }
            center.add(request)
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
