import SwiftUI
import WispCore

/// The saved conversations (⌘Y), newest first, filtered by the search field: ↑ ↓ move, ↩ reopens one
/// here, ⌘↩ in Ghostty, esc goes back. Scrolls once it outgrows the panel.
struct HistoryList: View {
    @ObservedObject var model: AppModel
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let entries = model.historyMatches
        if entries.isEmpty {
            Text(model.history.entries.isEmpty ? "No conversations yet" : "No conversations match “\(model.historyFilter)”")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == model.selectedHistoryEntry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        GeometryReader { geometry in
                            // Preferences do not reliably escape a ScrollView, so write the height directly.
                            Color.clear
                                .onAppear { contentHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { contentHeight = geometry.size.height }
                        })
                }
                .frame(height: min(max(contentHeight, 40), maxHeight))
                .onChange(of: model.selectedHistoryEntry) {
                    if let entry = model.historyMatches[safe: model.selectedHistoryEntry] { proxy.scrollTo(entry.id) }
                }
            }
        }
    }

    private func row(_ entry: SessionHistory.Entry, selected: Bool) -> some View {
        Button {
            model.reopen(entry)
        } label: {
            HStack(spacing: 10) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if entry.id == model.sessionID {
                    Text("Current")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .fixedSize()
                }
                Spacer(minLength: 12)
                Text(model.paths.abbreviate(entry.directory))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .trailing)
                    .layoutPriority(1)
                Group {
                    if model.reopening?.id == entry.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(RelativeTime.describe(entry.updatedAt))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.title)
    }
}

/// "5 min. ago", "yesterday": when a conversation was last used.
@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    static func describe(_ date: Date, relativeTo now: Date = Date()) -> String {
        formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
