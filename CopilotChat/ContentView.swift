import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(CopilotService.self) private var copilotService
    @Environment(ConversationStore.self) private var conversationStore

    @State private var showSettings = false

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        splitLayout
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            splitLayout
        } else {
            singleLayout
        }
        #endif
    }

    private var singleLayout: some View {
        ChatView()
            .background(Color.carbonBlack)
            .task {
                await settingsStore.connectAllServers()
                if authManager.isAuthenticated {
                    await copilotService.fetchModels()
                }
            }
    }

    private var splitLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ChatView(showToolbar: false)
                .background(Color.carbonBlack)
                .task {
                    await settingsStore.connectAllServers()
                    if authManager.isAuthenticated {
                        await copilotService.fetchModels()
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarView()

            Divider()
                .background(Color.carbonBorder)

            HStack(spacing: Carbon.spacingRelaxed) {
                Button {
                    conversationStore.startNewConversation(
                        currentMessages: copilotService.messages,
                        currentSummaryId: copilotService.summaryMessageId,
                        currentReasoningEffort: settingsStore.reasoningEffort
                    )
                    copilotService.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundStyle(Color.carbonTextSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.subheadline)
                        .foregroundStyle(Color.carbonTextSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Carbon.messagePaddingH)
            .padding(.vertical, Carbon.spacingRelaxed)
            .background(Color.carbonSurface)
        }
        .background(Color.carbonSurface)
    }
}