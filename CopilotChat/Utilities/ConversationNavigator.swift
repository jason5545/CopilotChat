import Foundation

@MainActor
enum ConversationNavigator {
    @discardableResult
    static func startNewProjectConversation(
        workspaceIdentifier: String,
        store: ConversationStore,
        copilotService: CopilotService,
        settingsStore: SettingsStore
    ) -> Bool {
        let currentWorkspaceIdentifier = settingsStore.appMode == .coding
            ? ConversationStore.currentWorkspaceIdentifier
            : nil

        guard WorkspaceManager.shared.switchWorkspace(to: workspaceIdentifier) else {
            WorkspaceManager.shared.requestWorkspaceSelection(
                for: workspaceIdentifier,
                action: .startProjectConversation
            )
            return false
        }

        settingsStore.appMode = .coding
        store.startNewConversation(
            currentMessages: copilotService.messages,
            currentSummaryId: copilotService.summaryMessageId,
            currentReasoningEffort: settingsStore.reasoningEffort,
            currentWorkspaceIdentifier: currentWorkspaceIdentifier
        )
        copilotService.newConversation()
        store.createConversation(workspaceIdentifier: ConversationStore.currentWorkspaceIdentifier ?? workspaceIdentifier)
        return true
    }

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
                WorkspaceManager.shared.requestWorkspaceSelection(
                    for: workspaceIdentifier,
                    action: .resumeConversation(id)
                )
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

    static func completePendingWorkspaceSelection(
        store: ConversationStore,
        copilotService: CopilotService,
        settingsStore: SettingsStore
    ) {
        guard let selection = WorkspaceManager.shared.consumeCompletedWorkspaceSelection() else { return }

        if let requestedWorkspaceIdentifier = selection.requestedWorkspaceIdentifier,
           !WorkspaceManager.matchesWorkspaceIdentifiers(requestedWorkspaceIdentifier, selection.selectedWorkspaceIdentifier) {
            store.reassignWorkspaceIdentifier(
                from: requestedWorkspaceIdentifier,
                to: selection.selectedWorkspaceIdentifier
            )
        }

        switch selection.action {
        case .resumeConversation(let id):
            _ = resumeConversation(
                id: id,
                store: store,
                copilotService: copilotService,
                settingsStore: settingsStore
            )
        case .startProjectConversation:
            _ = startNewProjectConversation(
                workspaceIdentifier: selection.selectedWorkspaceIdentifier,
                store: store,
                copilotService: copilotService,
                settingsStore: settingsStore
            )
        }
    }
}
