import SwiftUI

@main
struct CopilotChatApp: App {
    @State private var authManager = AuthManager()
    @State private var settingsStore = SettingsStore()
    @State private var conversationStore = ConversationStore()
    @State private var copilotService: CopilotService?
    @State private var providerRegistry: ProviderRegistry?

    var body: some Scene {
        WindowGroup {
            Group {
                if let copilotService {
                    ContentView()
                        .environment(authManager)
                        .environment(settingsStore)
                        .environment(conversationStore)
                        .environment(copilotService)
                } else {
                    ZStack {
                        Color.carbonBlack.ignoresSafeArea()
                        ProgressView()
                            .tint(Color.carbonAccent)
                    }
                }
            }
            .task {
                if copilotService == nil {
                    #if REVIEW
                    ReviewMode.configureDefaults(settingsStore)
                    #endif

                    let registry = ProviderRegistry(authManager: authManager)
                    providerRegistry = registry

                    let service = CopilotService(authManager: authManager, settingsStore: settingsStore)
                    service.setProviderRegistry(registry)
                    copilotService = service

                    await registry.loadProviders()

                    await PluginRegistry.shared.loadPlugins(
                        authManager: authManager,
                        settingsStore: settingsStore,
                        providerRegistry: registry
                    )

                    #if REVIEW
                    if ReviewMode.isEnabled {
                        ReviewMode.configureDefaults(registry, settingsStore: settingsStore)
                        await injectReviewConversations(service: service)
                    }
                    #endif
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    #if REVIEW
    private func injectReviewConversations(service: CopilotService) async {
        await conversationStore.ensureSeededConversations(ReviewMode.makeSampleConversations())
        if let current = conversationStore.currentConversationState() {
            service.loadMessages(current.messages, summaryMessageId: current.summaryMessageId)
            if let effort = current.reasoningEffort {
                settingsStore.reasoningEffort = effort
            }
            if let registry = providerRegistry {
                registry.activeProviderId = current.providerId ?? ReviewMode.defaultProviderId
                let modelId = current.modelId ?? ReviewMode.defaultModelId
                registry.activeModelId = modelId
                settingsStore.selectedModel = modelId
            }
        }
    }
    #endif
}
