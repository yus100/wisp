import SwiftUI
import WispCore

/// Slash-command suggestions under the input while a `/command` is being typed.
struct SuggestionList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let items = model.suggestions
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.name) { index, command in
                Button {
                    model.acceptSuggestion(command)
                } label: {
                    HStack(spacing: 10) {
                        Text("/" + command.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(command.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == model.selectedSuggestion ? Color.accentColor.opacity(0.22) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// Chips for what goes with the next question, each removable.
struct AttachmentStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.attachments) { attachment in
                    AttachmentChip(attachment: attachment) { model.removeAttachment(attachment.id) }
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 10)
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: Self.symbol(for: attachment.kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(attachment.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.label)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help(attachment.url.path)
    }

    static func symbol(for kind: Attachment.Kind) -> String {
        switch kind {
        case .window: "macwindow"
        case .image: "photo"
        case .file: "doc"
        }
    }
}
