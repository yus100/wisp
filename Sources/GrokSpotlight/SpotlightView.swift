import SwiftUI

struct SpotlightView: View {
    @ObservedObject var model: SpotlightModel
    let width: CGFloat
    let maxConversationHeight: CGFloat
    var onHeightChange: (CGFloat) -> Void

    @FocusState private var inputFocused: Bool
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            if model.hasConversation {
                Divider().opacity(0.5)
                conversation
            }
            if model.hasConversation || model.notice != nil {
                footer
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onHeightChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { onHeightChange(proxy.size.height) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.focusRequest) { inputFocused = true }
        .onAppear { inputFocused = true }
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(alignment: .center, spacing: 12) {
            leadingIcon.frame(width: 26, height: 26)
            TextField(placeholder, text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .light))
                .lineLimit(1...6)
                .focused($inputFocused)
            micButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var placeholder: String {
        if model.voice.active { return model.voice.finishing ? "Finishing…" : "Listening…" }
        return model.hasConversation ? "Ask a follow-up" : "Ask Grok anything"
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if model.voice.active {
            MicLevelView(level: model.voice.level, connecting: model.voice.connecting)
        } else if model.isWorking {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    private var micButton: some View {
        Button {
            if model.voice.active {
                model.finishVoice(send: true)
            } else {
                model.startVoice(mode: .handsFree)
            }
        } label: {
            Image(systemName: model.voice.active ? "stop.circle.fill" : "mic")
                .font(.system(size: 16))
                .foregroundStyle(model.voice.active ? Color.red : Color.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.voice.active ? "Stop and send" : "Voice")
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(model.turns) { turn in
                            TurnView(turn: turn)
                        }
                    }
                    Color.clear.frame(height: 0).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)
                // Preferences do not reliably escape a ScrollView, so write the measured height directly.
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { contentHeight = proxy.size.height }
                })
            }
            .frame(height: min(max(contentHeight, 40), maxConversationHeight))
            .onChange(of: model.turns.last?.answer) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.turns.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if model.isWorking {
                hint("⌘.", "Stop")
            } else {
                hint("↩", "Send")
            }
            hint("⌘↩", "Ghostty")
            hint("⌘N", "New")
            hint("esc", "Close")
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

private struct TurnView: View {
    let turn: SpotlightModel.Turn
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.query)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            steps
            if let status = turn.status, !turn.done {
                Text(status)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.orange)
            } else if turn.answer.isEmpty && !turn.done {
                Text(turn.tools.isEmpty ? "Thinking…" : "Working…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            if !turn.answer.isEmpty {
                MarkdownView(text: turn.answer).textSelection(.enabled)
            }
            if let error = turn.error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(.red).textSelection(.enabled)
            } else if turn.cancelled {
                Text("Stopped").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        if !turn.tools.isEmpty {
            if turn.done && !showSteps {
                Button {
                    showSteps = true
                } label: {
                    Label("\(turn.tools.count) step\(turn.tools.count == 1 ? "" : "s")", systemImage: "chevron.right")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    let shown = turn.done ? turn.tools : Array(turn.tools.suffix(4))
                    if !turn.done && turn.tools.count > shown.count {
                        Text("\(turn.tools.count - shown.count) earlier steps")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                    ForEach(shown) { tool in ToolRow(tool: tool) }
                }
            }
        }
    }
}

private struct ToolRow: View {
    let tool: SpotlightModel.ToolActivity

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch tool.status {
                case "completed": Image(systemName: "checkmark").foregroundStyle(.tertiary)
                case "failed": Image(systemName: "xmark").foregroundStyle(.red)
                default: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 12)
            Text(tool.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct MicLevelView: View {
    let level: Float
    let connecting: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.18))
                .scaleEffect(0.7 + CGFloat(level) * 0.6)
                .animation(.easeOut(duration: 0.12), value: level)
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(connecting ? Color.secondary : Color.red)
        }
    }
}
