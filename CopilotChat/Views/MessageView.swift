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
            userBubble
        case .assistant:
            assistantBubble
        case .tool:
            toolResultBubble
        case .system:
            EmptyView()
        }
    }

    // MARK: - User Message

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.content)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    // MARK: - Assistant Message

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.content.isEmpty {
                Group {
                    if isStreaming {
                        Text(message.content)
                    } else {
                        MarkdownView(text: message.content)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if let toolCalls = message.toolCalls {
                ForEach(toolCalls) { call in
                    toolCallCard(call)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    // MARK: - Tool Call Card

    private func toolCallCard(_ call: ToolCall) -> some View {
        let status = toolCallStatuses[call.id] ?? .pending

        return HStack(spacing: 10) {
            toolCallStatusIcon(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.function.name)
                    .font(.subheadline.bold())
                if case .failed(let error) = status {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let args = parseArgsSummary(call.function.arguments) {
                    Text(args)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if case .failed = status {
                Button {
                    onRetryToolCall?(call)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(toolCallBorderColor(status))
        )
    }

    @ViewBuilder
    private func toolCallStatusIcon(_ status: ToolCallStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .executing:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func toolCallBorderColor(_ status: ToolCallStatus) -> Color {
        switch status {
        case .pending: .gray.opacity(0.2)
        case .executing: .blue.opacity(0.3)
        case .completed: .green.opacity(0.3)
        case .failed: .red.opacity(0.3)
        }
    }

    // MARK: - Tool Result

    private var toolResultStatus: ToolCallStatus {
        if let id = message.toolCallId, let status = toolCallStatuses[id] {
            return status
        }
        return .completed
    }

    private var toolResultBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                toolCallStatusIcon(toolResultStatus)
                    .font(.caption)
                Text(message.toolName ?? "Tool Result")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Text(message.content)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(10)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
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
