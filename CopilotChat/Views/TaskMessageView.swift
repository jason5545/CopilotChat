import SwiftUI

struct TaskMessageView: View {
    let toolCallId: String
    @State private var tracker = TaskSessionTracker.shared
    @State private var isExpanded = false

    private var session: TaskSessionTracker.TaskSession? {
        tracker.session(forToolCallId: toolCallId)
    }

    var body: some View {
        if let session {
            VStack(alignment: .leading, spacing: 0) {
                taskHeader(session)
                if isExpanded {
                    expandedContent(session)
                } else {
                    collapsedPreview(session)
                }
            }
            .background(Color.carbonSurface)
            .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                    .stroke(borderColor(for: session.state), lineWidth: 0.5)
            )
            .onTapGesture {
                if session.state != .running {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }
        }
    }

    private func taskHeader(_ session: TaskSessionTracker.TaskSession) -> some View {
        HStack(spacing: 10) {
            agentIcon(for: session.state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.agentType.uppercased())
                        .font(.carbonMono(.caption2, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Color.carbonAccent)
                    if session.state == .running {
                        Text("RUNNING")
                            .font(.carbonMono(.caption2, weight: .semibold))
                            .kerning(0.8)
                            .foregroundStyle(Color.carbonTextTertiary)
                    } else {
                        Text(stateLabel(session.state))
                            .font(.carbonMono(.caption2, weight: .semibold))
                            .kerning(0.8)
                            .foregroundStyle(stateColor(session.state))
                    }
                }
                Text(session.description)
                    .font(.carbonSans(.caption))
                    .foregroundStyle(Color.carbonTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if session.state == .running {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Color.carbonAccent)
            } else {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonTextTertiary)
            }
        }
        .padding(Carbon.spacingRelaxed)
        .background(Color.carbonAccent.opacity(0.06))
    }

    private func collapsedPreview(_ session: TaskSessionTracker.TaskSession) -> some View {
        VStack(alignment: .leading, spacing: Carbon.spacingBase) {
            if !session.resultContent.isEmpty {
                Text(session.resultContent.prefix(200) + (session.resultContent.count > 200 ? "…" : ""))
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if session.iterations > 0 {
                    Label("\(session.iterations) iterations", systemImage: "arrow.triangle.2.circlepath")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }
                Spacer()
                if session.messages.count > 2 {
                    Label("\(session.messages.count) messages", systemImage: "bubble.left")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }
            }
        }
        .padding(Carbon.spacingRelaxed)
    }

    private func expandedContent(_ session: TaskSessionTracker.TaskSession) -> some View {
        VStack(alignment: .leading, spacing: Carbon.spacingRelaxed) {
            if session.messages.isEmpty && session.resultContent.isEmpty && session.state == .running {
                HStack {
                    Spacer()
                    ThinkingIndicator()
                    Text("Running subagent…")
                        .font(.carbonMono(.caption))
                        .foregroundStyle(Color.carbonTextTertiary)
                    Spacer()
                }
                .padding(.vertical, Carbon.spacingRelaxed)
            } else {
                ForEach(Array(session.messages.enumerated()), id: \.offset) { _, msg in
                    subagentMessageRow(msg)
                }

                if session.state == .completed, !session.resultContent.isEmpty {
                    Rectangle()
                        .fill(Color.carbonBorder.opacity(0.2))
                        .frame(height: 0.5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RESULT")
                            .font(.carbonMono(.caption2, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(Color.carbonTextTertiary)
                        Text(session.resultContent)
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Carbon.spacingRelaxed)
                    .background(Color.carbonElevated)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                }
            }

            if case .failed(let error) = session.state {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.carbonError)
                    Text(error)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonError)
                        .lineLimit(2)
                }
                .padding(Carbon.spacingRelaxed)
            }
        }
        .padding(Carbon.spacingRelaxed)
    }

    @ViewBuilder
    private func subagentMessageRow(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonAccent)
                Text(message.content.prefix(80) + (message.content.count > 80 ? "…" : ""))
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextSecondary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.vertical, 4)
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.carbonSuccess)
                    Text("AGENT")
                        .font(.carbonMono(.caption2, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Color.carbonSuccess)
                    if let toolCalls = message.toolCalls {
                        Text("· \(toolCalls.count) tool(s)")
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    Spacer()
                }
                if !message.content.isEmpty {
                    Text(message.content.prefix(150) + (message.content.count > 150 ? "…" : ""))
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonText)
                        .lineLimit(3)
                }
            }
            .padding(Carbon.spacingRelaxed)
            .background(Color.carbonElevated)
            .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))

        case .tool:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonSuccess)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.toolName ?? "Tool")
                        .font(.carbonMono(.caption2, weight: .semibold))
                        .foregroundStyle(Color.carbonTextSecondary)
                    Text(message.content.prefix(100) + (message.content.count > 100 ? "…" : ""))
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        case .system:
            EmptyView()
        }
    }

    private func agentIcon(for state: TaskAgentState) -> some View {
        Group {
            switch state {
            case .running:
                Image(systemName: "puzzlepiece.extension")
                    .font(.caption)
                    .foregroundStyle(Color.carbonAccent)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.carbonSuccess)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.carbonError)
            case .cancelled:
                Image(systemName: "slash.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.carbonTextTertiary)
            }
        }
        .frame(width: 20, height: 20)
        .background(
            Circle()
                .fill(stateColor(state).opacity(0.15))
        )
    }

    private func borderColor(for state: TaskAgentState) -> Color {
        switch state {
        case .running: Color.carbonAccent.opacity(0.35)
        case .completed: Color.carbonSuccess.opacity(0.3)
        case .failed: Color.carbonError.opacity(0.3)
        case .cancelled: Color.carbonBorder.opacity(0.4)
        }
    }

    private func stateColor(_ state: TaskAgentState) -> Color {
        switch state {
        case .running: Color.carbonAccent
        case .completed: Color.carbonSuccess
        case .failed: Color.carbonError
        case .cancelled: Color.carbonTextTertiary
        }
    }

    private func stateLabel(_ state: TaskAgentState) -> String {
        switch state {
        case .running: return "RUNNING"
        case .completed: return "COMPLETED"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        }
    }
}
