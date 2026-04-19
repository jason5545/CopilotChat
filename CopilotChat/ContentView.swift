import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(CopilotService.self) private var copilotService
    @Environment(ConversationStore.self) private var conversationStore
    @Environment(QuickSearchStore.self) private var quickSearchStore

    @State private var showSettings = false

    var body: some View {
        rootContent
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: Binding(
                get: { quickSearchStore.isPresented },
                set: { isPresented in
                    if isPresented {
                        quickSearchStore.present(quickSearchStore.openIntent)
                    } else {
                        quickSearchStore.dismiss()
                    }
                }
            )) {
                QuickSearchView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestSettings)) { _ in
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestQuickSearch)) { _ in
                quickSearchStore.present()
            }
    }

    @ViewBuilder
    private var rootContent: some View {
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarView()

            Divider()
                .background(Color.carbonBorder)

            HStack(spacing: Carbon.spacingRelaxed) {
                Button {
                    quickSearchStore.present()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(Color.carbonTextSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: [.command])

                Button {
                    ConversationNavigator.startNewConversation(
                        store: conversationStore,
                        copilotService: copilotService,
                        settingsStore: settingsStore
                    )
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
