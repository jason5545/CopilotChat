import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(CopilotService.self) private var copilotService

    var body: some View {
        ChatView()
            .task {
                // Connect MCP servers on launch
                await settingsStore.connectAllServers()
                // Fetch available models if authenticated
                if authManager.isAuthenticated {
                    await copilotService.fetchModels()
                }
            }
    }
}
