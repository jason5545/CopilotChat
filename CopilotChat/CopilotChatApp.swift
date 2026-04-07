import SwiftUI

@main
struct CopilotChatApp: App {
    @State private var authManager = AuthManager()
    @State private var settingsStore = SettingsStore()
    @State private var conversationStore = ConversationStore()
    @State private var copilotService: CopilotService?

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
                    ProgressView()
                }
            }
            .task {
                if copilotService == nil {
                    copilotService = CopilotService(authManager: authManager, settingsStore: settingsStore)
                }
            }
            .preferredColorScheme(nil) // Follow system setting
        }
    }
}
