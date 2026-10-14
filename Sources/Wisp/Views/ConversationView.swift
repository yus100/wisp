import SwiftUI
import WispCore

/// The turns, scrolling once they outgrow the panel and following the newest text as it streams.
struct ConversationView: View {
    let conversation: Conversation
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(conversation.turns) { TurnView(turn: $0) }
                    }
                    Color.clear.frame(height: 0).id(Self.bottom)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .background(GeometryReader { geometry in
                    // Preferences do not reliably escape a ScrollView, so write the height directly.
                    Color.clear
                        .onAppear { contentHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { contentHeight = geometry.size.height }
                })
            }
            .frame(height: min(max(contentHeight, 40), maxHeight))
            .onChange(of: conversation.turns.last?.answer) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: conversation.turns.count) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    private static let bottom = "bottom"
}

struct TurnView: View {
    let turn: Turn
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.query)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            steps
            if let notice = turn.notice {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(.orange)
            } else if turn.answer.isEmpty, turn.isRunning {
                Text(turn.steps.isEmpty ? "Thinking…" : "Working…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            if !turn.answer.isEmpty {
                MarkdownView(text: turn.answer).textSelection(.enabled)
            }
            switch turn.state {
            case .failed(let message):
                Text(message).font(.system(size: 12.5)).foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Text("Stopped").font(.system(size: 12)).foregroundStyle(.tertiary)
            case .running, .finished:
                EmptyView()
            }
        }
    }

    /// While running, the latest steps; afterwards, a one-line summary that expands on click.
    @ViewBuilder
    private var steps: some View {
        if !turn.steps.isEmpty {
            if !turn.isRunning && !showSteps {
                Button {
                    showSteps = true
                } label: {
                    Label("\(turn.steps.count) step\(turn.steps.count == 1 ? "" : "s")", systemImage: "chevron.right")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                let shown = turn.isRunning ? Array(turn.steps.suffix(4)) : turn.steps
                VStack(alignment: .leading, spacing: 3) {
                    if shown.count < turn.steps.count {
                        Text("\(turn.steps.count - shown.count) earlier steps")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(shown) { StepRow(step: $0) }
                }
            }
        }
    }
}

struct StepRow: View {
    let step: Turn.Step

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch step.status {
                case .completed: Image(systemName: "checkmark").foregroundStyle(.tertiary)
                case .failed: Image(systemName: "xmark").foregroundStyle(.red)
                case .running: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 12)
            Text(step.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
