import SwiftUI

struct SidebarView: View {
    @Environment(ConversationStore.self) private var store
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(AuthManager.self) private var authManager

    @State private var searchText = ""

    private var filteredConversations: [Conversation] {
        let scoped = store.conversationsForCurrentWorkspace(settingsStore.appMode)
        guard !searchText.isEmpty else { return scoped }
        let query = searchText.lowercased()
        return scoped.filter { $0.title.lowercased().contains(query) }
    }

    var body: some View {
        Group {
            if filteredConversations.isEmpty {
                VStack(spacing: Carbon.spacingRelaxed) {
                    Spacer()
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.carbonTextTertiary)
                    VStack(spacing: Carbon.spacingTight) {
                        Text("No Conversations")
                            .font(.carbonSerif(.subheadline))
                            .foregroundStyle(Color.carbonTextSecondary)
                        Text("Start a new chat to begin.")
                            .font(.carbonSans(.caption))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                conversationList
            }
        }
        .background(Color.carbonBlack)
    }

    private var conversationList: some View {
        List(selection: Binding(
            get: { store.currentConversationId },
            set: { id in
                if let id {
                    resumeConversation(id)
                }
            }
        )) {
            ForEach(filteredConversations) { conversation in
                SidebarConversationRow(
                    conversation: conversation,
                    isCurrent: conversation.id == store.currentConversationId
                )
                .tag(conversation.id)
                .listRowBackground(
                    conversation.id == store.currentConversationId
                        ? Color.carbonElevated
                        : Color.carbonSurface
                )
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteConversation(conversation.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: "Search")
    }

    private func resumeConversation(_ id: UUID) {
        guard let conversation = store.conversations.first(where: { $0.id == id }) else { return }
        copilotService.stopStreaming()
        let result = store.switchToConversation(
            conversation.id,
            currentMessages: copilotService.messages,
            currentSummaryId: copilotService.summaryMessageId,
            currentReasoningEffort: settingsStore.reasoningEffort
        )
        copilotService.loadMessages(result.messages, summaryMessageId: result.summaryMessageId)
        if let effort = result.reasoningEffort {
            settingsStore.reasoningEffort = effort
        }
        if let providerId = result.providerId, let registry = copilotService.providerRegistry {
            registry.activeProviderId = providerId
        }
        if let modelId = result.modelId, let registry = copilotService.providerRegistry {
            registry.activeModelId = modelId
        }
    }
}

private struct SidebarConversationRow: View {
    let conversation: Conversation
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: Carbon.spacingRelaxed) {
            if isCurrent {
                Circle()
                    .fill(Color.carbonAccent)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(isCurrent
                        ? .carbonSans(.subheadline, weight: .semibold)
                        : .carbonSans(.subheadline))
                    .foregroundStyle(isCurrent ? Color.carbonText : Color.carbonTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(conversation.userMessageCount) msg\(conversation.userMessageCount == 1 ? "" : "s")")
                    Text("·")
                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}