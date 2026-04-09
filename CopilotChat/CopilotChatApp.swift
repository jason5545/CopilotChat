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
                    let registry = ProviderRegistry(authManager: authManager)
                    providerRegistry = registry

                    let service = CopilotService(authManager: authManager, settingsStore: settingsStore)
                    service.setProviderRegistry(registry)
                    copilotService = service

                    // Load models.dev providers in background
                    await registry.loadProviders()
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
