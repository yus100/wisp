import SwiftUI

/// Notices (with an optional settings button) on the left, keyboard hints on the right.
struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if let notice = model.notice {
                Text(notice.text)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let title = notice.actionTitle, let url = notice.actionURL {
                    Button(title) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .fixedSize()
                }
            }
            Spacer(minLength: 8)
            if model.isShowingHistory {
                hint("↩", "Open")
                hint("⌘↩", "Ghostty")
                hint("esc", "Back")
            } else if !model.conversation.isEmpty {
                if model.isWorking { hint("⌘.", "Stop") } else { hint("↩", "Send") }
                hint("⌘↩", "Ghostty")
                hint("⌘N", "New")
                hint("⌘Y", "History")
                hint("esc", "Close")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.medium).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.tertiary)
        }
        .fixedSize()
    }
}
