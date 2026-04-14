import SwiftUI

struct ConversationHistoryView: View {
    @Environment(ConversationStore.self) private var store
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""

    private var filteredConversations: [Conversation] {
        guard !searchText.isEmpty else { return store.conversations }
        let query = searchText.lowercased()
        return store.conversations.filter { $0.title.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.conversations.isEmpty {
                    ZStack {
                        Color.carbonBlack.ignoresSafeArea()
                        VStack(spacing: 16) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(Color.carbonTextTertiary)
                            VStack(spacing: 6) {
                                Text("No Conversations")
                                    .font(.carbonSerif(.headline))
                                    .foregroundStyle(Color.carbonTextSecondary)
                                Text("Your conversation history will appear here.")
                                    .font(.carbonSans(.caption))
                                    .foregroundStyle(Color.carbonTextTertiary)
                            }
                        }
                    }
                } else {
                    conversationList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.carbonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("HISTORY")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !store.conversations.isEmpty {
                        Button {
                            store.deleteAllConversations()
                            copilotService.newConversation()
                            dismiss()
                        } label: {
                            Text("Clear All")
                                .font(.carbonSans(.caption))
                                .foregroundStyle(Color.carbonError)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonAccent)
                    }
                }
            }
        }
    }

    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { conversation in
                Button {
                    resumeConversation(conversation)
                } label: {
                    ConversationRow(
                        conversation: conversation,
                        isCurrent: conversation.id == store.currentConversationId
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.carbonSurface)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.deleteConversation(conversation.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        renameText = conversation.title
                        renamingConversation = conversation
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Color.carbonAccent)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .searchable(text: $searchText, prompt: "Search conversations")
        .alert("Rename Conversation", isPresented: Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingConversation = nil }
            Button("Save") {
                if let conv = renamingConversation, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.renameConversation(conv.id, to: renameText.trimmingCharacters(in: .whitespaces))
                }
                renamingConversation = nil
            }
        } message: {
            Text("Enter a new name for this conversation.")
        }
    }

    private func resumeConversation(_ conversation: Conversation) {
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
        // Restore provider/model if conversation has them
        if let providerId = result.providerId, let registry = copilotService.providerRegistry {
            registry.activeProviderId = providerId
        }
        if let modelId = result.modelId, let registry = copilotService.providerRegistry {
            registry.activeModelId = modelId
        }
        dismiss()
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Active indicator
            if isCurrent {
                Circle()
                    .fill(Color.carbonAccent)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 6, height: 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .font(isCurrent
                        ? .carbonSans(.body, weight: .semibold)
                        : .carbonSans(.body))
                    .foregroundStyle(isCurrent ? Color.carbonText : Color.carbonTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(conversation.userMessageCount) msg\(conversation.userMessageCount == 1 ? "" : "s")")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)

                    Text("·")
                        .foregroundStyle(Color.carbonTextTertiary)

                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
