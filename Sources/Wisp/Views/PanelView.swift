import SwiftUI

/// The panel's content: input bar, the conversation (once there is one), and a footer.
/// Reports its height so the window can grow and shrink around it.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var layout: PanelLayout
    var onHeightChange: (CGFloat) -> Void
    var onModelMenu: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            InputBar(model: model, voice: voice, onModelMenu: onModelMenu)
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
        .background(GeometryReader { proxy in
            // Preferences do not reliably propagate here, so report the height directly.
            Color.clear
                .onAppear { onHeightChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { onHeightChange(proxy.size.height) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
