import Foundation

@MainActor
enum ConversationNavigator {
    @discardableResult
    static func startNewConversation(
        workspaceIdentifier: String? = nil,
        store: ConversationStore,
        copilotService: CopilotService,
        settingsStore: SettingsStore
    ) -> Bool {
        let currentWorkspaceIdentifier = settingsStore.appMode == .coding
            ? ConversationStore.currentWorkspaceIdentifier
            : nil

        if let workspaceIdentifier {
            guard WorkspaceManager.shared.switchWorkspace(to: workspaceIdentifier) else {
                NotificationCenter.default.post(name: .requestWorkspaceSelection, object: nil)
                return false
            }
            settingsStore.appMode = .coding
        }

        store.startNewConversation(
            currentMessages: copilotService.messages,
            currentSummaryId: copilotService.summaryMessageId,
            currentReasoningEffort: settingsStore.reasoningEffort,
            currentWorkspaceIdentifier: currentWorkspaceIdentifier
        )
        copilotService.newConversation()
        return true
    }

    @discardableResult
    static func resumeConversation(
        id: UUID,
        store: ConversationStore,
        copilotService: CopilotService,
        settingsStore: SettingsStore
    ) -> Bool {
        guard let conversation = store.conversations.first(where: { $0.id == id }) else { return false }
        let currentWorkspaceIdentifier = settingsStore.appMode == .coding ? ConversationStore.currentWorkspaceIdentifier : nil

        if let workspaceIdentifier = conversation.workspaceIdentifier {
            guard WorkspaceManager.shared.switchWorkspace(to: workspaceIdentifier) else {
                NotificationCenter.default.post(name: .requestWorkspaceSelection, object: nil)
                return false
            }
            settingsStore.appMode = .coding
        }

        copilotService.stopStreaming()
        let result = store.switchToConversation(
            conversation.id,
            currentMessages: copilotService.messages,
            currentSummaryId: copilotService.summaryMessageId,
            currentReasoningEffort: settingsStore.reasoningEffort,
            currentWorkspaceIdentifier: currentWorkspaceIdentifier
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
        return true
    }
}
