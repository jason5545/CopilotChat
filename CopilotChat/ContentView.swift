import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(CopilotService.self) private var copilotService

    var body: some View {
        ChatView()
            .background(Color.carbonBlack)
            .task {
                await settingsStore.connectAllServers()
                if authManager.isAuthenticated {
                    await copilotService.fetchModels()
                }
            }
    }
}
