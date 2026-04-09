import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let toolCallStatuses: [String: ToolCallStatus]
    let toolCallServerNames: [String: String]
    let isStreaming: Bool
    let onRetryToolCall: ((ToolCall) -> Void)?
    let onPermissionDecision: ((PermissionDecision) -> Void)?
    let isSummary: Bool
    let onEdit: ((ChatMessage) -> Void)?
    let onRegenerate: (() -> Void)?

    init(
        message: ChatMessage,
        toolCallStatuses: [String: ToolCallStatus] = [:],
        toolCallServerNames: [String: String] = [:],
        isStreaming: Bool = false,
        onRetryToolCall: ((ToolCall) -> Void)? = nil,
        onPermissionDecision: ((PermissionDecision) -> Void)? = nil,
        isSummary: Bool = false,
        onEdit: ((ChatMessage) -> Void)? = nil,
        onRegenerate: (() -> Void)? = nil
    ) {
        self.message = message
        self.toolCallStatuses = toolCallStatuses
        self.toolCallServerNames = toolCallServerNames
        self.isStreaming = isStreaming
        self.onRetryToolCall = onRetryToolCall
        self.onPermissionDecision = onPermissionDecision
        self.isSummary = isSummary
        self.onEdit = onEdit
        self.onRegenerate = onRegenerate
    }

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .assistant:
            if isSummary {
                summaryCard
            } else {
                assistantMessage
            }
        case .tool:
            toolResultMessage
        case .system:
            EmptyView()
        }
    }

    // MARK: - User Message

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                Spacer(minLength: 72)
                UserBubbleView(message: message)
            }
            if let onEdit {
                Button {
                    onEdit(message)
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(Color.carbonTextTertiary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingTight)
    }

    // MARK: - Assistant Message

    private var assistantContentBlock: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.carbonAccent.opacity(0.5))
                .frame(width: Carbon.accentBarWidth)
                .padding(.vertical, 2)

            MarkdownView(text: message.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color.carbonText)
                .padding(.leading, Carbon.spacingRelaxed)
                .padding(.trailing, Carbon.spacingTight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: Carbon.spacingBase) {
            if !message.content.isEmpty {
                assistantContentBlock
            }

            if let toolCalls = message.toolCalls {
                ForEach(toolCalls) { call in
                    toolCallCard(call)
                }
            }

            if let reason = message.finishReason, reason == .length || reason == .error {
                let icon = reason == .length ? "exclamationmark.triangle" : "bolt.slash"
                let label = reason == .length ? "Response truncated (token limit)" : "Response interrupted (connection lost)"
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption2)
                    Text(label).font(.carbonMono(.caption2))
                }
                .foregroundStyle(Color.carbonWarning)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.carbonWarning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
            }

            HStack(spacing: 8) {
                if let onRegenerate {
                    Button {
                        onRegenerate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(Color.carbonTextTertiary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                if !isStreaming, let usage = message.tokenUsage {
                    Text("\(formatTokenCount(usage.completionTokens)) tokens")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingTight)
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Color.carbonWarning)
                Text("CONTEXT COMPACTED")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(Color.carbonWarning)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.carbonWarning.opacity(0.06))

            Rectangle()
                .fill(Color.carbonWarning.opacity(0.12))
                .frame(height: 0.5)

            MarkdownView(text: message.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color.carbonText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color.carbonSurface)
        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                .stroke(Color.carbonWarning.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingTight)
    }

    // MARK: - Tool Call Card

    @ViewBuilder
    private func toolCallCard(_ call: ToolCall) -> some View {
        let status = toolCallStatuses[call.id] ?? .pending

        if status == .awaitingPermission {
            permissionCard(call)
        } else {
            standardToolCallCard(call, status: status)
        }
    }

    private func standardToolCallCard(_ call: ToolCall, status: ToolCallStatus) -> some View {
        HStack(spacing: 10) {
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

    // MARK: - Permission Card

    private func permissionCard(_ call: ToolCall) -> some View {
        let serverName = toolCallServerNames[call.id] ?? "Unknown"

        return VStack(spacing: 0) {
            // Header stripe
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.carbonAccent)
                Text(serverName.uppercased())
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(Color.carbonAccent)
                Spacer()
                Text("PERMISSION")
                    .font(.carbonMono(.caption2, weight: .semibold))
                    .kerning(1.0)
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.carbonAccent.opacity(0.08))

            // Divider
            Rectangle()
                .fill(Color.carbonAccent.opacity(0.15))
                .frame(height: 0.5)

            // Tool info
            VStack(alignment: .leading, spacing: 6) {
                Text("Wants to run")
                    .font(.carbonSans(.caption))
                    .foregroundStyle(Color.carbonTextTertiary)
                Text(call.function.name)
                    .font(.carbonMono(.subheadline, weight: .bold))
                    .foregroundStyle(Color.carbonText)
                if let args = parseArgsSummary(call.function.arguments) {
                    Text(args)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Divider
            Rectangle()
                .fill(Color.carbonBorder.opacity(0.3))
                .frame(height: 0.5)

            // Actions
            VStack(spacing: 10) {
                // Primary: Allow for this chat
                Button {
                    onPermissionDecision?(.allowForChat)
                } label: {
                    Text("Allow for this chat")
                        .font(.carbonMono(.caption, weight: .bold))
                        .foregroundStyle(Color.carbonBlack)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.carbonAccent)
                        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                }
                .buttonStyle(.plain)

                // Secondary row
                HStack(spacing: 0) {
                    Button {
                        onPermissionDecision?(.allowOnce)
                    } label: {
                        Text("Allow once")
                            .font(.carbonMono(.caption2, weight: .medium))
                            .foregroundStyle(Color.carbonTextSecondary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        onPermissionDecision?(.allowAlways)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                                .font(.caption2)
                            Text("Always allow")
                                .font(.carbonMono(.caption2, weight: .medium))
                        }
                        .foregroundStyle(Color.carbonAccent.opacity(0.7))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        onPermissionDecision?(.deny)
                    } label: {
                        Text("Deny")
                            .font(.carbonMono(.caption2, weight: .semibold))
                            .foregroundStyle(Color.carbonError)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.carbonSurface)
        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                .stroke(Color.carbonAccent.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.carbonAccent.opacity(0.06), radius: 12, y: 4)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
        .animation(.easeOut(duration: 0.25), value: toolCallStatuses[call.id])
    }

    @ViewBuilder
    private func toolCallStatusIcon(_ status: ToolCallStatus) -> some View {
        switch status {
        case .awaitingPermission:
            Image(systemName: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(Color.carbonAccent)
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
        case .awaitingPermission: Color.carbonAccent.opacity(0.35)
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

// MARK: - User Bubble (shared between message list and context menu preview)

struct UserBubbleView: View {
    let message: ChatMessage
    var lineLimit: Int? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.carbonSans(.body))
                    .foregroundStyle(Color.carbonText)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(lineLimit)
            }
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.messagePaddingV)
        .background(Color.carbonUserBubble)
        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Carbon.radiusLarge)
                .stroke(Color.carbonUserBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Context Menu Preview

/// Standalone preview for context menu — rendered outside the flipped ScrollView
/// so it is not affected by the parent's rotationEffect/scaleEffect transforms.
struct MessageContextPreview: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:    UserBubbleView(message: message, lineLimit: 12)
        case .assistant: assistantPreview
        default:       fallbackPreview
        }
    }

    private var assistantPreview: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.carbonAccent.opacity(0.5))
                .frame(width: Carbon.accentBarWidth)
                .padding(.vertical, 2)
            MarkdownView(text: String(message.content.prefix(800)))
                .foregroundStyle(Color.carbonText)
                .padding(.leading, Carbon.spacingRelaxed)
                .padding(.trailing, Carbon.spacingTight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 360)
        .padding(.vertical, Carbon.spacingTight)
        .background(Color.carbonBlack)
    }

    private var fallbackPreview: some View {
        Text(message.content.prefix(200))
            .font(.carbonMono(.caption2))
            .foregroundStyle(Color.carbonTextSecondary)
            .lineLimit(8)
            .padding(Carbon.spacingRelaxed)
            .background(Color.carbonSurface)
            .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
    }
}
