import SwiftUI
import WispRendering

struct MarkdownView: View {
    let text: String

    var body: some View {
        AnswerView(text: text)
    }
}
