import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let onToolCall: ((ToolCall) -> Void)?

    init(message: ChatMessage, onToolCall: ((ToolCall) -> Void)? = nil) {
        self.message = message
        self.onToolCall = onToolCall
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
                MarkdownView(text: message.content)
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
        Button {
            onToolCall?(call)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.function.name)
                        .font(.subheadline.bold())
                    if let args = parseArgsSummary(call.function.arguments) {
                        Text(args)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.blue)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tool Result

    private var toolResultBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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
