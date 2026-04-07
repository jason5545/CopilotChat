import SwiftUI

struct ConversationHistoryView: View {
    @Environment(ConversationStore.self) private var store
    @Environment(CopilotService.self) private var copilotService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Your conversation history will appear here.")
                    )
                } else {
                    conversationList
                }
            }
            .navigationTitle("History")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.conversations.isEmpty {
                        Button("Clear All", role: .destructive) {
                            store.deleteAllConversations()
                            copilotService.newConversation()
                            dismiss()
                        }
                        .foregroundStyle(.red)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var conversationList: some View {
        List {
            ForEach(store.conversations) { conversation in
                Button {
                    resumeConversation(conversation)
                } label: {
                    ConversationRow(
                        conversation: conversation,
                        isCurrent: conversation.id == store.currentConversationId
                    )
                }
                .buttonStyle(.plain)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.deleteConversation(store.conversations[index].id)
                }
            }
        }
        .listStyle(.plain)
    }

    private func resumeConversation(_ conversation: Conversation) {
        copilotService.stopStreaming()
        let messages = store.switchToConversation(
            conversation.id,
            currentMessages: copilotService.messages
        )
        copilotService.loadMessages(messages)
        dismiss()
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation
    let isCurrent: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(conversation.userMessageCount) message\(conversation.userMessageCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
