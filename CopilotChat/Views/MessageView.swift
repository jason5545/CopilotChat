import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let toolCallStatuses: [String: ToolCallStatus]
    let isStreaming: Bool
    let onRetryToolCall: ((ToolCall) -> Void)?

    init(
        message: ChatMessage,
        toolCallStatuses: [String: ToolCallStatus] = [:],
        isStreaming: Bool = false,
        onRetryToolCall: ((ToolCall) -> Void)? = nil
    ) {
        self.message = message
        self.toolCallStatuses = toolCallStatuses
        self.isStreaming = isStreaming
        self.onRetryToolCall = onRetryToolCall
    }

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .assistant:
            assistantMessage
        case .tool:
            toolResultMessage
        case .system:
            EmptyView()
        }
    }

    // MARK: - User Message

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 72)
            Text(message.content)
                .font(.carbonSans(.body))
                .foregroundStyle(Color.carbonText)
                .padding(.horizontal, Carbon.messagePaddingH)
                .padding(.vertical, Carbon.messagePaddingV)
                .background(Color.carbonUserBubble)
                .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusLarge))
                .overlay(
                    RoundedRectangle(cornerRadius: Carbon.radiusLarge)
                        .stroke(Color.carbonUserBorder, lineWidth: 0.5)
                )
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingTight)
    }

    // MARK: - Assistant Message

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: Carbon.spacingBase) {
            if !message.content.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    // Accent bar
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.carbonAccent.opacity(0.5))
                        .frame(width: Carbon.accentBarWidth)
                        .padding(.vertical, 2)

                    // Content
                    Group {
                        if isStreaming {
                            Text(message.content)
                                .font(.carbonSerif(.body))
                        } else {
                            MarkdownView(text: message.content)
                        }
                    }
                    .textSelection(.enabled)
                    .foregroundStyle(Color.carbonText)
                    .padding(.leading, Carbon.spacingRelaxed)
                    .padding(.trailing, Carbon.spacingTight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let toolCalls = message.toolCalls {
                ForEach(toolCalls) { call in
                    toolCallCard(call)
                }
            }
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingTight)
    }

    // MARK: - Tool Call Card

    private func toolCallCard(_ call: ToolCall) -> some View {
        let status = toolCallStatuses[call.id] ?? .pending

        return HStack(spacing: 10) {
            toolCallStatusIcon(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.function.name)
                    .font(.carbonMono(.caption, weight: .semibold))
                    .foregroundStyle(Color.carbonText)
                if case .failed(let error) = status {
                    Text(error)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonError)
                        .lineLimit(2)
                } else if let args = parseArgsSummary(call.function.arguments) {
                    Text(args)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if case .failed = status {
                Button {
                    onRetryToolCall?(call)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.carbonAccent)
                        .frame(width: 26, height: 26)
                        .background(Color.carbonAccentMuted)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Carbon.spacingRelaxed)
        .background(Color.carbonSurface)
        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                .stroke(toolCallBorderColor(status), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func toolCallStatusIcon(_ status: ToolCallStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(Color.carbonTextTertiary)
        case .executing:
            ProgressView()
                .scaleEffect(0.6)
                .tint(Color.carbonAccent)
        case .completed:
            Image(systemName: "checkmark")
                .font(.caption2.bold())
                .foregroundStyle(Color.carbonBlack)
                .frame(width: 18, height: 18)
                .background(Color.carbonSuccess)
                .clipShape(Circle())
        case .failed:
            Image(systemName: "xmark")
                .font(.caption2.bold())
                .foregroundStyle(Color.carbonBlack)
                .frame(width: 18, height: 18)
                .background(Color.carbonError)
                .clipShape(Circle())
        }
    }

    private func toolCallBorderColor(_ status: ToolCallStatus) -> Color {
        switch status {
        case .pending: Color.carbonBorder.opacity(0.4)
        case .executing: Color.carbonAccent.opacity(0.3)
        case .completed: Color.carbonSuccess.opacity(0.3)
        case .failed: Color.carbonError.opacity(0.3)
        }
    }

    // MARK: - Tool Result

    private var toolResultStatus: ToolCallStatus {
        if let id = message.toolCallId, let status = toolCallStatuses[id] {
            return status
        }
        return .completed
    }

    private var toolResultMessage: some View {
        VStack(alignment: .leading, spacing: Carbon.spacingTight) {
            HStack(spacing: 6) {
                toolCallStatusIcon(toolResultStatus)
                    .font(.caption2)
                Text(message.toolName ?? "Tool Result")
                    .font(.carbonMono(.caption2, weight: .semibold))
                    .foregroundStyle(Color.carbonTextSecondary)
            }
            Text(message.content)
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextSecondary)
                .lineLimit(10)
                .padding(Carbon.spacingRelaxed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.carbonCodeBg)
                .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Carbon.radiusSmall)
                        .stroke(Color.carbonBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingTight)
    }

    // MARK: - Helpers

    private func parseArgsSummary(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json.isEmpty ? nil : json
        }
        let pairs = dict.map { "\($0.key): \($0.value)" }
        return pairs.joined(separator: ", ")
    }
}
