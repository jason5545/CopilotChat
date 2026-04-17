import SwiftUI

@main
struct CopilotChatApp: App {
    @State private var authManager = AuthManager()
    @State private var settingsStore = SettingsStore()
    @State private var conversationStore = ConversationStore()
    @State private var quickSearchStore = QuickSearchStore()
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
                        .environment(quickSearchStore)
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

                    // Initialize plugin system
                    await PluginRegistry.shared.loadPlugins(
                        authManager: authManager,
                        settingsStore: settingsStore,
                        providerRegistry: registry
                    )

                    await registry.refreshCodexModels()

                    // iCloud sync
                    settingsStore.startObservingKVStoreChanges()
                    await conversationStore.syncWithCloud()
                }
            }
            .preferredColorScheme(.dark)
        }
#if os(macOS)
        .commands {
            CommandMenu("Navigate") {
                Button("Quick Search") {
                    quickSearchStore.present()
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }
#endif
    }
}
