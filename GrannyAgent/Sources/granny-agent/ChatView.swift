import SwiftUI
import GrannyCore

/// The conversation tab ("Đôi co với Ngoại"): streams deltas from
/// `granny-engine` over `<state dir>/engine.sock`, offers `chat.abort` while a
/// turn is in flight, and shows a quiet degraded notice when no engine is
/// connected.
struct ChatView: View {
    @ObservedObject var viewModel: GrannyViewModel
    let onSend: (String) -> Void
    let onAbort: () -> Void

    @State private var draft = ""

    private var isStreaming: Bool {
        viewModel.activeChatRunID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !viewModel.engineReady {
                degradedBanner
            }
            transcript
            composer
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(GrannyLines.chatTitle)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(GrannyTheme.text)
                Text(GrannyLines.chatSubtitle)
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(GrannyTheme.text.opacity(0.68))
            }
            Spacer(minLength: 0)
            reasoningToggle
        }
    }

    private var reasoningToggle: some View {
        HStack(spacing: 7) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12))
                .foregroundStyle(
                    viewModel.chatReasoning ? GrannyTheme.gold : GrannyTheme.text.opacity(0.58))
            Text(GrannyLines.chatReasoningToggle)
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(
                    viewModel.chatReasoning ? GrannyTheme.text : GrannyTheme.text.opacity(0.68))
            Toggle("", isOn: $viewModel.chatReasoning)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(GrannyTheme.gold)
        }
        .help(GrannyLines.chatReasoningHelp)
        .pointingHandOnHover()
    }

    private var degradedBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(GrannyTheme.gold.opacity(0.75))
                .frame(width: 7, height: 7)
            Text(GrannyLines.chatDegraded)
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(GrannyTheme.text.opacity(0.78))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .grannyCard(cornerRadius: 8)
    }

    @ViewBuilder
    private var transcript: some View {
        if viewModel.chatTurns.isEmpty {
            VStack {
                Spacer()
                Text(GrannyLines.chatEmpty)
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(GrannyTheme.text.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            .padding(16)
            .grannyCard(cornerRadius: 10)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.chatTurns) { turn in
                            turnRow(turn)
                                .id(turn.id)
                        }
                    }
                    .padding(14)
                }
                .grannyCard(cornerRadius: 10)
                .onChange(of: viewModel.chatTurns) { _, turns in
                    if let last = turns.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func turnRow(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.role == .you ? GrannyLines.chatSpeakerYou : GrannyLines.chatSpeakerGranny)
                .font(.system(size: 10, weight: .semibold, design: .serif))
                .tracking(1.1)
                .foregroundStyle(
                    turn.role == .you
                        ? GrannyTheme.text.opacity(0.5)
                        : GrannyTheme.gold)
            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(GrannyTheme.text)
                    .textSelection(.enabled)
            } else if turn.streaming {
                Text("…")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(GrannyTheme.text.opacity(0.5))
            }
            if let error = turn.error {
                Text(error)
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(GrannyTheme.gold.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    turn.role == .you
                        ? GrannyTheme.background.opacity(0.45)
                        : GrannyTheme.card.opacity(0.75)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GrannyTheme.hairline))
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(GrannyLines.chatPlaceholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(GrannyTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .grannyCard(cornerRadius: 8)
                .disabled(isStreaming)
                .onSubmit { submit() }

            if isStreaming {
                Button(GrannyLines.chatAbortButton) {
                    onAbort()
                }
                .buttonStyle(GrannySecondaryButtonStyle())
            } else {
                Button(GrannyLines.chatSendButton) {
                    submit()
                }
                .buttonStyle(GrannyPrimaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        draft = ""
        onSend(trimmed)
    }
}
