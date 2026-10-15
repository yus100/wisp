import SwiftUI

/// The panel's content: input bar, slash-command suggestions and attachments, the conversation (once
/// there is one), and a footer. Reports its height so the window can grow and shrink around it.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var layout: PanelLayout
    var onHeightChange: (CGFloat) -> Void
    var onModelMenu: () -> Void
    var onAttachMenu: () -> Void
    var onDropFiles: ([URL]) -> Void
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            InputBar(model: model, voice: voice, onModelMenu: onModelMenu, onAttachMenu: onAttachMenu)
            if !model.suggestions.isEmpty {
                SuggestionList(model: model)
            }
            if !model.attachments.isEmpty {
                AttachmentStrip(model: model)
            }
            if !model.conversation.isEmpty {
                Divider().opacity(0.5)
                ConversationView(conversation: model.conversation, maxHeight: layout.maxConversationHeight)
            }
            if !model.conversation.isEmpty || model.notice != nil {
                FooterView(model: model)
            }
        }
        .frame(width: PanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { onDropFiles(files) }
            return !files.isEmpty
        } isTargeted: {
            isDropTarget = $0
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: PanelController.cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .background(
            GeometryReader { proxy in
                // Preferences do not reliably propagate here, so report the height directly.
                Color.clear
                    .onAppear { onHeightChange(proxy.size.height) }
                    .onChange(of: proxy.size.height) { onHeightChange(proxy.size.height) }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
