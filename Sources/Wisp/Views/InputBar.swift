import SwiftUI

/// Status icon, the question field, the attach button, the model chip, and the mic button. While the
/// history list shows, the field searches it instead.
struct InputBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceController
    var onModelMenu: () -> Void
    var onAttachMenu: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon.frame(width: 26, height: 26)
            // One field for both, so it keeps focus when the history list opens and closes.
            TextField(placeholder, text: model.isShowingHistory ? $model.historyFilter : $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .light))
                .lineLimit(1...6)
                .focused($focused)
                .disabled(model.isHandingOff)
                .accessibilityLabel(model.isShowingHistory ? "Search conversations" : "Question")
            if !model.isShowingHistory {
                attachButton
                modelChip
                micButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .onChange(of: model.focusRequest) { focused = true }
        .onAppear { focused = true }
    }

    private var placeholder: String {
        if model.isShowingHistory { return "Search conversations" }
        return switch voice.state {
        case .starting, .listening: "Listening…"
        case .finishing: "Finishing…"
        case .idle where !model.attachments.isEmpty: "Ask about this"
        case .idle: model.conversation.isEmpty ? "Ask anything" : "Ask a follow-up"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if voice.isActive {
            MicLevelView(level: voice.level, waiting: voice.state == .starting)
        } else if model.isWorking || model.isHandingOff || model.reopening != nil {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: model.isShowingHistory ? "clock.arrow.circlepath" : "sparkle")
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
        }
    }

    private var attachButton: some View {
        Button(action: onAttachMenu) {
            Image(systemName: "paperclip")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Attach a window or files (⌘⇧A attaches the window you came from; ⌘V pastes files and images)")
        .accessibilityLabel("Attach")
    }

    private var modelChip: some View {
        Button(action: onModelMenu) {
            HStack(spacing: 3) {
                Text(model.modelLabel).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Model and reasoning effort (⌘M)")
        .accessibilityLabel("Model: \(model.modelLabel)")
    }

    private var micButton: some View {
        Button {
            if voice.isActive { voice.finish(send: true) } else { model.startVoice(.handsFree) }
        } label: {
            Image(systemName: voice.isActive ? "stop.circle.fill" : "mic")
                .font(.system(size: 16))
                .foregroundStyle(voice.isActive ? Color.red : Color.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(voice.isActive ? "Stop and send" : "Voice")
        .accessibilityLabel(voice.isActive ? "Stop and send" : "Start voice input")
    }
}

/// A mic that pulses with the input level; grey until audio is flowing.
struct MicLevelView: View {
    let level: Float
    let waiting: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.18))
                .scaleEffect(0.7 + CGFloat(level) * 0.6)
                .animation(.easeOut(duration: 0.12), value: level)
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(waiting ? Color.secondary : Color.red)
        }
        .accessibilityLabel("Listening")
    }
}
