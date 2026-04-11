import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAddMCPServer = false
    @State private var showProviderPicker = false
    @State private var providerAPIKeyInput = ""
    @State private var selectedProviderForKey: ModelsDevProvider?
    @State private var showModelPicker = false
    @State private var isSystemPromptCollapsed = false
    @State private var isProviderCollapsed = false
    @State private var isMCPCollapsed = false
    @State private var isToolAccessCollapsed = false
    @State private var isMCPPermissionsCollapsed = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                providerSection
                modelSection
                systemPromptSection
                mcpSection
                toolAccessModeSection
                mcpPermissionsSection
                pluginsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.carbonBlack)
            .toolbarBackground(Color.carbonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SETTINGS")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonAccent)
                    }
                }
            }
            .navigationDestination(isPresented: $showProviderPicker) {
                ProviderPickerView(registry: copilotService.providerRegistry)
            }
            .navigationDestination(item: $selectedProviderForKey) { provider in
                ProviderKeyEditView(provider: provider, registry: copilotService.providerRegistry)
            }
            .sheet(isPresented: $showAddMCPServer) {
                MCPServerEditView(server: nil) { server in
                    settingsStore.addServer(server)
                    Task { await settingsStore.connectServer(server) }
                }
            }
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            if authManager.isAuthenticated {
                HStack(spacing: 14) {
                    if let url = authManager.avatarUrl, let imageURL = URL(string: url) {
                        AsyncImage(url: imageURL) { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle()
                                .fill(Color.carbonElevated)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.carbonTextTertiary)
                                )
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.carbonAccent.opacity(0.3), lineWidth: 1)
                        )
                    } else {
                        Circle()
                            .fill(Color.carbonElevated)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.carbonTextTertiary)
                            )
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(authManager.username ?? "GitHub User")
                            .font(.carbonSans(.body, weight: .semibold))
                            .foregroundStyle(Color.carbonText)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.carbonSuccess)
                                .frame(width: 6, height: 6)
                            Text("Connected")
                                .font(.carbonMono(.caption2))
                                .foregroundStyle(Color.carbonSuccess)
                        }
                    }

                    Spacer()
                }
                .listRowBackground(Color.carbonSurface)

                Button("Sign Out", role: .destructive) {
                    authManager.signOut()
                }
                .font(.carbonSans(.subheadline))
                .foregroundStyle(Color.carbonError)
                .listRowBackground(Color.carbonSurface)
            } else if authManager.isAuthenticating {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Color.carbonAccent)
                            .scaleEffect(0.8)
                        Text("Waiting for authorization...")
                            .font(.carbonSans(.subheadline))
                            .foregroundStyle(Color.carbonTextSecondary)
                    }

                    if let code = authManager.deviceFlowUserCode {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ENTER THIS CODE ON GITHUB")
                                .font(.carbonMono(.caption2, weight: .semibold))
                                .foregroundStyle(Color.carbonTextTertiary)
                                .kerning(0.8)
                            Text(code)
                                .font(.carbonMono(.title2, weight: .bold))
                                .foregroundStyle(Color.carbonAccent)
                                .textSelection(.enabled)
                        }

                        if let urlString = authManager.deviceFlowVerificationURL,
                           let url = URL(string: urlString) {
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2)
                                    Text("Open GitHub")
                                        .font(.carbonMono(.caption, weight: .medium))
                                }
                                .foregroundStyle(Color.carbonBlack)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.carbonAccent)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.carbonSurface)
            } else {
                Button {
                    Task { await authManager.startDeviceFlow() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key")
                            .foregroundStyle(Color.carbonAccent)
                        Text("Sign in with GitHub")
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonText)
                    }
                }
                .listRowBackground(Color.carbonSurface)

                if let error = authManager.authError {
                    Text(error)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonError)
                        .listRowBackground(Color.carbonSurface)
                }
            }
        } header: {
            CarbonSectionHeader(title: "Account")
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        DisclosureGroup(isExpanded: $isProviderCollapsed) {
            Section {
                if let registry = copilotService.providerRegistry {
                    ForEach(registry.configuredProviders) { provider in
                        let isActive = registry.activeProviderId == provider.id
                        Button {
                            registry.activeProviderId = provider.id
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .stroke(isActive ? Color.carbonAccent : Color.carbonBorder, lineWidth: 1.5)
                                        .frame(width: 18, height: 18)
                                    if isActive {
                                        Circle()
                                            .fill(Color.carbonAccent)
                                            .frame(width: 10, height: 10)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.name)
                                        .font(.carbonSans(.subheadline, weight: .medium))
                                        .foregroundStyle(isActive ? Color.carbonText : Color.carbonTextSecondary)
                                    HStack(spacing: 6) {
                                        Text("\(provider.models.count) MODELS")
                                            .font(.carbonMono(.caption2, weight: .medium))
                                            .kerning(0.4)
                                            .foregroundStyle(Color.carbonTextTertiary)
                                        if provider.isCodingPlan {
                                            Text("CODING PLAN")
                                                .font(.carbonMono(.caption2, weight: .bold))
                                                .kerning(0.3)
                                                .foregroundStyle(Color.carbonAccent)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.carbonAccentMuted)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                }

                                Spacer()

                                if provider.id == "openai-codex" {
                                    if registry.codexAuth.isAuthenticated {
                                        Button {
                                            registry.codexAuth.signOut()
                                        } label: {
                                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                                .font(.caption2)
                                                .foregroundStyle(Color.carbonTextTertiary)
                                                .padding(6)
                                                .background(Color.carbonElevated)
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if registry.loadAPIKey(for: provider.id) != nil {
                                        Button {
                                            selectedProviderForKey = provider
                                        } label: {
                                            Image(systemName: "key")
                                                .font(.caption2)
                                                .foregroundStyle(Color.carbonTextTertiary)
                                                .padding(6)
                                                .background(Color.carbonElevated)
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            registry.removeAPIKey(for: provider.id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption2)
                                                .foregroundStyle(Color.carbonTextTertiary)
                                                .padding(6)
                                                .background(Color.carbonElevated)
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } else if provider.id != "github-copilot" {
                                    Button {
                                        selectedProviderForKey = provider
                                    } label: {
                                        Image(systemName: "key")
                                            .font(.caption2)
                                            .foregroundStyle(Color.carbonTextTertiary)
                                            .padding(6)
                                            .background(Color.carbonElevated)
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        registry.removeAPIKey(for: provider.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption2)
                                            .foregroundStyle(Color.carbonTextTertiary)
                                            .padding(6)
                                            .background(Color.carbonElevated)
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(
                            isActive
                                ? Color.carbonAccent.opacity(0.06)
                                : Color.carbonSurface
                        )
                    }

                    Button {
                        showProviderPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(Color.carbonBlack)
                                .frame(width: 18, height: 18)
                                .background(Color.carbonAccent)
                                .clipShape(Circle())
                            Text("Add Provider")
                                .font(.carbonSans(.subheadline, weight: .medium))
                                .foregroundStyle(Color.carbonAccent)
                            Spacer()
                            Text("120+")
                                .font(.carbonMono(.caption2, weight: .medium))
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                    }
                    .listRowBackground(Color.carbonSurface)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Color.carbonAccent)
                            .scaleEffect(0.7)
                        Text("Loading providers...")
                            .font(.carbonMono(.caption))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    .listRowBackground(Color.carbonSurface)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isProviderCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonTextTertiary)
                    .frame(width: 16)
                Text("Provider")
                    .font(.carbonMono(.caption2, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color.carbonText)
            }
        }
        .disclosureGroupStyle(.automatic)
        .listRowBackground(Color.carbonSurface)
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            if let registry = copilotService.providerRegistry,
               let provider = registry.modelsDevProviders[registry.activeProviderId] {
                let selectedId = registry.activeModelId
                let displayModel = provider.models[selectedId]
                NavigationLink {
                    ModelPickerView(
                        provider: provider,
                        selectedModelId: Binding(
                            get: { selectedId },
                            set: { newId in
                                if let newId {
                                    registry.activeModelId = newId
                                    if registry.activeProviderId == "github-copilot" {
                                        settingsStore.selectedModel = newId
                                    }
                                }
                            }
                        )
                    )
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayModel?.name ?? selectedId)
                                .font(.carbonSans(.subheadline))
                                .foregroundStyle(Color.carbonText)
                            if let model = displayModel {
                                ModelTagsView(model: model)
                            }
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.carbonSurface)
            } else {
                Text(settingsStore.selectedModel)
                    .font(.carbonMono(.subheadline))
                    .foregroundStyle(Color.carbonText)
                    .listRowBackground(Color.carbonSurface)
            }
        } header: {
            CarbonSectionHeader(title: "Model")
        }
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
        DisclosureGroup(isExpanded: $isSystemPromptCollapsed) {
            @Bindable var store = settingsStore
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $store.systemPrompt)
                    .font(.carbonSans(.subheadline))
                    .foregroundStyle(Color.carbonText)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .tint(Color.carbonAccent)

                if store.systemPrompt != SettingsStore.defaultSystemPrompt {
                    Button {
                        store.systemPrompt = SettingsStore.defaultSystemPrompt
                    } label: {
                        Text("Reset to Default")
                            .font(.carbonMono(.caption2, weight: .medium))
                            .foregroundStyle(Color.carbonTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.carbonElevated)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.carbonSurface)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSystemPromptCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonTextTertiary)
                    .frame(width: 16)
                Text("System Prompt")
                    .font(.carbonMono(.caption2, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color.carbonText)
            }
        }
        .disclosureGroupStyle(.automatic)
        .listRowBackground(Color.carbonSurface)
    }

    // MARK: - MCP Section

    private var mcpSection: some View {
        DisclosureGroup(isExpanded: $isMCPCollapsed) {
            Section {
                ForEach(settingsStore.mcpServers) { server in
                    NavigationLink {
                        MCPServerDetailView(server: server)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name)
                                    .font(.carbonSans(.subheadline, weight: .medium))
                                    .foregroundStyle(Color.carbonText)
                                Text(server.url)
                                    .font(.carbonMono(.caption2))
                                    .foregroundStyle(Color.carbonTextTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            serverStatusIndicator(for: server)
                        }
                    }
                    .listRowBackground(Color.carbonSurface)
                }
                .onDelete { offsets in
                    settingsStore.removeServer(at: offsets)
                }

                Button {
                    showAddMCPServer = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundStyle(Color.carbonAccent)
                        Text("Add MCP Server")
                            .font(.carbonSans(.subheadline))
                            .foregroundStyle(Color.carbonAccent)
                    }
                }
                .listRowBackground(Color.carbonSurface)
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    if !settingsStore.mcpTools.isEmpty {
                        Text("\(settingsStore.mcpTools.count) tools available")
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    if !settingsStore.alwaysAllowedServers.isEmpty {
                        Text("\(settingsStore.alwaysAllowedServers.count) server(s) always allowed")
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonSuccess.opacity(0.7))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isMCPCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonTextTertiary)
                    .frame(width: 16)
                Text("MCP Servers")
                    .font(.carbonMono(.caption2, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color.carbonText)
            }
        }
        .disclosureGroupStyle(.automatic)
        .listRowBackground(Color.carbonSurface)
    }

    // MARK: - Tool Access Mode Section

    private var toolAccessModeSection: some View {
        DisclosureGroup(isExpanded: $isToolAccessCollapsed) {
            Section {
                @Bindable var store = settingsStore
                if settingsStore.mcpServers.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption)
                            .foregroundStyle(Color.carbonTextTertiary)
                        Text("Add MCP servers to configure tool loading")
                            .font(.carbonSans(.caption))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    .listRowBackground(Color.carbonSurface)
                } else {
                    Picker("Tool Access Mode", selection: $store.toolAccessMode) {
                        ForEach(ToolAccessMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .font(.carbonSans(.subheadline, weight: .medium))
                    .foregroundStyle(Color.carbonText)
                    .listRowBackground(Color.carbonSurface)
                }
            } footer: {
                Text(settingsStore.toolAccessMode.description)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isToolAccessCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonTextTertiary)
                    .frame(width: 16)
                Text("Tool Loading")
                    .font(.carbonMono(.caption2, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color.carbonText)
            }
        }
        .disclosureGroupStyle(.automatic)
        .listRowBackground(Color.carbonSurface)
    }

    // MARK: - MCP Permissions Section

    private var mcpPermissionsSection: some View {
        DisclosureGroup(isExpanded: $isMCPPermissionsCollapsed) {
            Section {
                if settingsStore.mcpServers.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(Color.carbonTextTertiary)
                        Text("No MCP servers configured")
                            .font(.carbonSans(.caption))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    .listRowBackground(Color.carbonSurface)
                } else {
                    ForEach(settingsStore.mcpServers) { server in
                        let summary = permissionSummary(for: server.name)
                        NavigationLink {
                            MCPPermissionDetailView(serverName: server.name)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(.carbonSans(.subheadline, weight: .medium))
                                        .foregroundStyle(Color.carbonText)
                                    Text(summary.label)
                                        .font(.carbonMono(.caption2))
                                        .foregroundStyle(summary.color)
                                }
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.carbonSurface)
                    }
                }
            } footer: {
                Text("Tap a server to configure per-tool permissions.")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isMCPPermissionsCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(Color.carbonTextTertiary)
                    .frame(width: 16)
                Text("Tool Permissions")
                    .font(.carbonMono(.caption2, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color.carbonText)
            }
        }
        .disclosureGroupStyle(.automatic)
        .listRowBackground(Color.carbonSurface)
    }

    private func permissionSummary(for serverName: String) -> (label: String, color: Color) {
        let tools = settingsStore.toolsForServer(serverName)
        let overrides = tools.compactMap { settingsStore.toolPermissionOverrides[$0.name] }
        let hasDenied = overrides.contains(.alwaysDeny)
        let hasAllowed = overrides.contains(.alwaysAllow)

        if settingsStore.alwaysAllowedServers.contains(serverName) {
            if hasDenied { return ("Allowed · some tools blocked", .carbonWarning) }
            return ("Always allowed", .carbonSuccess)
        }
        if hasAllowed && hasDenied { return ("Mixed", .carbonWarning) }
        if hasAllowed { return ("Some tools allowed", .carbonAccent) }
        if hasDenied { return ("Some tools blocked", .carbonWarning) }
        return ("Ask every time", .carbonTextTertiary)
    }

    private func serverStatusIndicator(for server: MCPServerConfig) -> some View {
        Group {
            if !server.isEnabled {
                Circle()
                    .stroke(Color.carbonTextTertiary, lineWidth: 1)
                    .frame(width: 8, height: 8)
            } else if settingsStore.mcpConnectionErrors[server.id] != nil {
                Circle()
                    .fill(Color.carbonError)
                    .frame(width: 8, height: 8)
            } else if settingsStore.mcpClients[server.id] != nil {
                Circle()
                    .fill(Color.carbonSuccess)
                    .frame(width: 8, height: 8)
            } else {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(Color.carbonAccent)
            }
        }
    }

    // MARK: - Plugins Section

    private var pluginsSection: some View {
        Section {
            NavigationLink {
                PluginPermissionsView()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Built-in Plugins")
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonText)
                        Text("\(PluginRegistry.shared.pluginCount) plugin(s)")
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    Spacer()
                }
            }
            .listRowBackground(Color.carbonSurface)
        } header: {
            CarbonSectionHeader(title: "Plugins")
        } footer: {
            Text("\(PluginRegistry.shared.allPluginTools().count) tool(s) available")
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(.carbonSans(.subheadline))
                    .foregroundStyle(Color.carbonTextSecondary)
                Spacer()
                Text("1.0.0")
                    .font(.carbonMono(.subheadline))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            .listRowBackground(Color.carbonSurface)
        } header: {
            CarbonSectionHeader(title: "About")
        }
    }
}

// MARK: - Plugin Permissions View

struct PluginPermissionsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var isBraveKeyVisible = false
    @State private var braveAPIKeyInput = ""

    var body: some View {
        List {
            Section {
                ForEach(PluginRegistry.shared.registeredPlugins.filter { $0.id != "com.copilotchat.filesystem" && $0.id != "com.copilotchat.github" }, id: \.id) { plugin in
                    pluginRow(plugin)
                        .listRowBackground(Color.carbonSurface)
                }

                if PluginRegistry.shared.pluginCount == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.caption)
                            .foregroundStyle(Color.carbonTextTertiary)
                        Text("No plugins loaded")
                            .font(.carbonSans(.caption))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    .listRowBackground(Color.carbonSurface)
                }
            } header: {
                CarbonSectionHeader(title: "Plugins")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(PluginRegistry.shared.pluginCount) plugin(s)")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                    Text("\(PluginRegistry.shared.allPluginTools().count) tool(s) available")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .navigationTitle("Built-in Plugins")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if settingsStore.hasBraveSearchAPIKey {
                braveAPIKeyInput = settingsStore.braveSearchAPIKey
            }
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: any Plugin) -> some View {
        if plugin.id == "com.copilotchat.brave-search" {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name)
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonText)
                        Text("\(PluginRegistry.shared.hooks(for: plugin.id)?.tools.count ?? 0) tools")
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { PluginRegistry.shared.isEnabled(pluginId: plugin.id) },
                        set: { PluginRegistry.shared.setEnabled(pluginId: plugin.id, enabled: $0) }
                    ))
                    .tint(Color.carbonAccent)
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    Group {
                        if isBraveKeyVisible {
                            TextField("API Key", text: $braveAPIKeyInput)
                        } else {
                            SecureField("API Key", text: $braveAPIKeyInput)
                        }
                    }
                    .font(.carbonMono(.caption))
                    .foregroundStyle(Color.carbonText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Button {
                        isBraveKeyVisible.toggle()
                    } label: {
                        Image(systemName: isBraveKeyVisible ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    Button {
                        settingsStore.braveSearchAPIKey = braveAPIKeyInput
                    } label: {
                        Text("Save")
                            .font(.carbonMono(.caption2, weight: .bold))
                            .foregroundStyle(braveAPIKeyInput.isEmpty ? Color.carbonTextTertiary : Color.carbonBlack)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(braveAPIKeyInput.isEmpty ? Color.carbonElevated : Color.carbonAccent)
                            .clipShape(Capsule())
                    }
                    .disabled(braveAPIKeyInput.isEmpty)
                    .buttonStyle(.plain)

                    if settingsStore.hasBraveSearchAPIKey {
                        Button {
                            settingsStore.braveSearchAPIKey = ""
                            braveAPIKeyInput = ""
                        } label: {
                            Text("Remove")
                                .font(.carbonMono(.caption2, weight: .medium))
                                .foregroundStyle(Color.carbonError)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.carbonElevated)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name)
                        .font(.carbonSans(.subheadline, weight: .medium))
                        .foregroundStyle(Color.carbonText)
                    Text("\(PluginRegistry.shared.hooks(for: plugin.id)?.tools.count ?? 0) tools")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { PluginRegistry.shared.isEnabled(pluginId: plugin.id) },
                    set: { PluginRegistry.shared.setEnabled(pluginId: plugin.id, enabled: $0) }
                ))
                .tint(Color.carbonAccent)
                .labelsHidden()
            }
        }
    }
}

// MARK: - MCP Permission Detail View

struct MCPPermissionDetailView: View {
    @Environment(SettingsStore.self) private var settingsStore

    let serverName: String

    private var isServerAllowed: Bool {
        settingsStore.alwaysAllowedServers.contains(serverName)
    }

    private var tools: [MCPTool] {
        settingsStore.toolsForServer(serverName)
    }

    var body: some View {
        List {
            // Server-level permission
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow all tools")
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonText)
                        Text("Skip permission prompts for this server")
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isServerAllowed },
                        set: { newValue in
                            if newValue {
                                settingsStore.allowServerAlways(serverName)
                            } else {
                                settingsStore.revokeAlwaysAllow(serverName)
                            }
                        }
                    ))
                    .tint(Color.carbonAccent)
                    .labelsHidden()
                }
                .listRowBackground(Color.carbonSurface)
            } header: {
                CarbonSectionHeader(title: "Server")
            }

            // Per-tool permissions
            Section {
                if tools.isEmpty {
                    Text("No tools connected")
                        .font(.carbonSans(.caption))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .listRowBackground(Color.carbonSurface)
                } else {
                    ForEach(tools) { tool in
                        toolPermissionRow(tool)
                            .listRowBackground(Color.carbonSurface)
                    }
                }
            } header: {
                CarbonSectionHeader(title: "Tools")
            } footer: {
                Text("Per-tool overrides take priority over the server setting.")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .navigationTitle(serverName)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func toolPermissionRow(_ tool: MCPTool) -> some View {
        let override = settingsStore.toolPermissionOverrides[tool.name]

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.carbonMono(.caption, weight: .semibold))
                    .foregroundStyle(Color.carbonText)
                Text(tool.description)
                    .font(.carbonSans(.caption))
                    .foregroundStyle(Color.carbonTextSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                permissionChip("Default", isSelected: override == nil) {
                    settingsStore.setToolOverride(tool.name, nil)
                }
                permissionChip("Allow", isSelected: override == .alwaysAllow, color: .carbonSuccess) {
                    settingsStore.setToolOverride(tool.name, .alwaysAllow)
                }
                permissionChip("Block", isSelected: override == .alwaysDeny, color: .carbonError) {
                    settingsStore.setToolOverride(tool.name, .alwaysDeny)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func permissionChip(
        _ label: String,
        isSelected: Bool,
        color: Color = .carbonAccent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.carbonMono(.caption2, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.carbonBlack : Color.carbonTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : Color.carbonElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MCP Server Detail View

struct MCPServerDetailView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    let server: MCPServerConfig

    @State private var name: String
    @State private var url: String
    @State private var headersText: String
    @State private var isEnabled: Bool

    init(server: MCPServerConfig) {
        self.server = server
        _name = State(initialValue: server.name)
        _url = State(initialValue: server.url)
        _headersText = State(initialValue: Self.headersToText(server.headers))
        _isEnabled = State(initialValue: server.isEnabled)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .font(.carbonSans(.body))
                    .foregroundStyle(Color.carbonText)
                TextField("URL", text: $url)
                    .font(.carbonMono(.body))
                    .foregroundStyle(Color.carbonText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Toggle("Enabled", isOn: $isEnabled)
                    .tint(Color.carbonAccent)
            } header: {
                CarbonSectionHeader(title: "Server")
            }
            .listRowBackground(Color.carbonSurface)

            Section {
                TextEditor(text: $headersText)
                    .font(.carbonMono(.body))
                    .foregroundStyle(Color.carbonText)
                    .frame(minHeight: 80)
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
            } header: {
                CarbonSectionHeader(title: "Headers")
            } footer: {
                Text("One per line: Header-Name: value")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
            .listRowBackground(Color.carbonSurface)

            if let error = settingsStore.mcpConnectionErrors[server.id] {
                Section {
                    Text(error)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonError)
                } header: {
                    CarbonSectionHeader(title: "Error")
                }
                .listRowBackground(Color.carbonSurface)
            }

            Section {
                Button {
                    let updated = MCPServerConfig(
                        id: server.id,
                        name: name,
                        url: url,
                        headers: Self.textToHeaders(headersText),
                        isEnabled: isEnabled
                    )
                    settingsStore.updateServer(updated)
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.carbonSans(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.carbonAccent)
                }
                .disabled(name.isEmpty || url.isEmpty)

                Button {
                    Task {
                        let current = MCPServerConfig(
                            id: server.id,
                            name: name,
                            url: url,
                            headers: Self.textToHeaders(headersText),
                            isEnabled: true
                        )
                        settingsStore.updateServer(current)
                        await settingsStore.connectServer(current)
                    }
                } label: {
                    Text("Reconnect")
                        .font(.carbonSans(.subheadline))
                        .foregroundStyle(Color.carbonText)
                }
            }
            .listRowBackground(Color.carbonSurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .navigationTitle(server.name)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    static func headersToText(_ headers: [String: String]) -> String {
        headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    static func textToHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                headers[key] = value
            }
        }
        return headers
    }
}

// MARK: - MCP Server Edit View (Add New)

struct MCPServerEditView: View {
    @Environment(\.dismiss) private var dismiss

    let server: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var headersText = ""
    @State private var isEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .font(.carbonSans(.body))
                        .foregroundStyle(Color.carbonText)
                    TextField("URL", text: $url)
                        .font(.carbonMono(.body))
                        .foregroundStyle(Color.carbonText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Toggle("Enabled", isOn: $isEnabled)
                        .tint(Color.carbonAccent)
                } header: {
                    CarbonSectionHeader(title: "Server")
                }
                .listRowBackground(Color.carbonSurface)

                Section {
                    TextEditor(text: $headersText)
                        .font(.carbonMono(.body))
                        .foregroundStyle(Color.carbonText)
                        .frame(minHeight: 80)
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                } header: {
                    CarbonSectionHeader(title: "Headers")
                } footer: {
                    Text("One per line: Header-Name: value")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }
                .listRowBackground(Color.carbonSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.carbonBlack)
            .toolbarBackground(Color.carbonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("ADD SERVER")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.carbonSans(.subheadline))
                            .foregroundStyle(Color.carbonTextSecondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let newServer = MCPServerConfig(
                            name: name,
                            url: url,
                            headers: MCPServerDetailView.textToHeaders(headersText),
                            isEnabled: isEnabled
                        )
                        onSave(newServer)
                        dismiss()
                    } label: {
                        Text("Add")
                            .font(.carbonSans(.subheadline, weight: .semibold))
                            .foregroundStyle(Color.carbonAccent)
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}

// MARK: - Provider Picker Sheet

struct ProviderPickerView: View {
    let registry: ProviderRegistry?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var apiKeyInput = ""
    @State private var selectedProvider: ModelsDevProvider?
    @State private var isKeyVisible = false
    @State private var augmentAuthError: String?

    private var filteredProviders: [ModelsDevProvider] {
        guard let registry else { return [] }
        let all = registry.allProvidersSorted
        if searchText.isEmpty { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if let selected = selectedProvider {
                apiKeyEntryView(for: selected)
            } else {
                providerListView
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.carbonSurface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(selectedProvider != nil ? "CONNECT" : "PROVIDERS")
                    .font(.carbonMono(.caption, weight: .bold))
                    .kerning(2.5)
                    .foregroundStyle(Color.carbonText)
            }
        }
        .navigationBarBackButtonHidden(selectedProvider != nil)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectedProvider != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedProvider = nil
                            apiKeyInput = ""
                            isKeyVisible = false
                            augmentAuthError = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.caption2.weight(.semibold))
                            Text("Back")
                        }
                        .font(.carbonSans(.subheadline))
                        .foregroundStyle(Color.carbonAccent)
                    }
                }
            }
        }
    }

    // MARK: - Provider List

    private var providerListView: some View {
        List {
            ForEach(filteredProviders) { provider in
                let isConfigured = registry?.hasAPIKey(for: provider.id) ?? false
                Button {
                    if isConfigured {
                        registry?.activeProviderId = provider.id
                        dismiss()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedProvider = provider
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        // Provider icon placeholder — accent initial
                        Text(String(provider.name.prefix(1)).uppercased())
                            .font(.carbonMono(.caption2, weight: .bold))
                            .foregroundStyle(isConfigured ? Color.carbonBlack : Color.carbonAccent)
                            .frame(width: 28, height: 28)
                            .background(isConfigured ? Color.carbonAccent : Color.carbonAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .font(.carbonSans(.subheadline, weight: .medium))
                                .foregroundStyle(Color.carbonText)
                            HStack(spacing: 6) {
                                Text("\(provider.models.count)")
                                    .font(.carbonMono(.caption2, weight: .medium))
                                    .foregroundStyle(Color.carbonTextTertiary)
                                + Text(" models")
                                    .font(.carbonMono(.caption2))
                                    .foregroundStyle(Color.carbonTextTertiary)

                                if provider.isCodingPlan {
                                    Text("CODING PLAN")
                                        .font(.carbonMono(.caption2, weight: .bold))
                                        .kerning(0.3)
                                        .foregroundStyle(Color.carbonAccent)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.carbonAccentMuted)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                if provider.isChinaRegion {
                                    Text("CN")
                                        .font(.carbonMono(.caption2, weight: .bold))
                                        .foregroundStyle(Color.carbonWarning)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.carbonWarning.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        }

                        Spacer()

                        if isConfigured {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.carbonSuccess)
                                    .frame(width: 6, height: 6)
                                Text("ACTIVE")
                                    .font(.carbonMono(.caption2, weight: .medium))
                                    .kerning(0.3)
                                    .foregroundStyle(Color.carbonSuccess)
                            }
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(isConfigured ? Color.carbonAccent.opacity(0.04) : Color.carbonSurface)
            }
        }
        .searchable(text: $searchText, prompt: "Search 120+ providers...")
    }

    // MARK: - API Key Entry

    private func apiKeyEntryView(for provider: ModelsDevProvider) -> some View {
        List {
            // Provider header card
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text(String(provider.name.prefix(1)).uppercased())
                            .font(.carbonMono(.body, weight: .bold))
                            .foregroundStyle(Color.carbonAccent)
                            .frame(width: 40, height: 40)
                            .background(Color.carbonAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .font(.carbonSans(.headline, weight: .semibold))
                                .foregroundStyle(Color.carbonText)
                            Text("\(provider.models.count) models available")
                                .font(.carbonMono(.caption2))
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                    }

                    if !provider.env.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "key")
                                .font(.caption2)
                                .foregroundStyle(Color.carbonTextTertiary)
                            Text(provider.env.joined(separator: " · "))
                                .font(.carbonMono(.caption2))
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.carbonSurface)
            }

            // API Key / Session JSON input
            if provider.id == "augment" {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Group {
                                if isKeyVisible {
                                    TextField("{\"accessToken\":\"...\",\"tenantURL\":\"...\"}", text: $apiKeyInput)
                                } else {
                                    SecureField("Paste session JSON", text: $apiKeyInput)
                                }
                            }
                            .font(.carbonMono(.subheadline))
                            .foregroundStyle(Color.carbonText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                            Button {
                                isKeyVisible.toggle()
                            } label: {
                                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                    .font(.caption)
                                    .foregroundStyle(Color.carbonTextTertiary)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.caption2)
                                .foregroundStyle(Color.carbonTextTertiary)
                            Text("Run **auggie token print** in your terminal")
                                .font(.carbonMono(.caption2))
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                    }
                    .listRowBackground(Color.carbonSurface)

                    Button {
                        guard let registry, !apiKeyInput.isEmpty else { return }
                        augmentAuthError = nil

                        // Parse the JSON input
                        guard let data = apiKeyInput.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let accessToken = json["accessToken"] as? String, !accessToken.isEmpty,
                              let tenantURL = json["tenantURL"] as? String, !tenantURL.isEmpty else {
                            augmentAuthError = "Please paste the full session JSON from auggie token print"
                            return
                        }

                        guard tenantURL.hasPrefix("https://") else {
                            augmentAuthError = "Invalid tenantURL: must start with https://"
                            return
                        }

                        registry.saveAugmentCredentials(accessToken: accessToken, tenantURL: tenantURL)
                        registry.activeProviderId = provider.id
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Spacer()
                            Image(systemName: "checkmark.circle")
                                .font(.subheadline.weight(.medium))
                            Text("Connect")
                                .font(.carbonSans(.subheadline, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(apiKeyInput.isEmpty ? Color.carbonTextTertiary : Color.carbonBlack)
                        .padding(.vertical, 6)
                        .background(apiKeyInput.isEmpty ? Color.carbonElevated : Color.carbonAccent)
                        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                    }
                    .disabled(apiKeyInput.isEmpty)
                    .listRowBackground(Color.carbonSurface)

                    if let error = augmentAuthError {
                        Text(error)
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonWarning)
                            .listRowBackground(Color.carbonSurface)
                    }
                } header: {
                    CarbonSectionHeader(title: "Session JSON")
                }
            } else {
                Section {
                    HStack {
                        Group {
                            if isKeyVisible {
                                TextField("sk-...", text: $apiKeyInput)
                            } else {
                                SecureField("Paste your API key", text: $apiKeyInput)
                            }
                        }
                        .font(.carbonMono(.subheadline))
                        .foregroundStyle(Color.carbonText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                        Button {
                            isKeyVisible.toggle()
                        } label: {
                            Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                .font(.caption)
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Color.carbonSurface)

                    Button {
                        guard let registry, !apiKeyInput.isEmpty else { return }
                        registry.saveAPIKey(apiKeyInput, for: provider.id)
                        registry.activeProviderId = provider.id
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Spacer()
                            Image(systemName: "checkmark.circle")
                                .font(.subheadline.weight(.medium))
                            Text("Connect")
                                .font(.carbonSans(.subheadline, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(apiKeyInput.isEmpty ? Color.carbonTextTertiary : Color.carbonBlack)
                        .padding(.vertical, 6)
                        .background(apiKeyInput.isEmpty ? Color.carbonElevated : Color.carbonAccent)
                        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                    }
                    .disabled(apiKeyInput.isEmpty)
                    .listRowBackground(Color.carbonSurface)
                } header: {
                    CarbonSectionHeader(title: "API Key")
                }
            }

            // OAuth option (for providers that support it)
            if provider.id == "openai-codex" {
                Section {
                    if registry?.codexAuth.isAuthenticating == true {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(Color.carbonAccent)
                                .scaleEffect(0.8)
                            VStack(alignment: .leading, spacing: 2) {
                                if let code = registry?.codexAuth.deviceUserCode {
                                    Text("Code: \(code)")
                                        .font(.carbonMono(.subheadline, weight: .bold))
                                        .foregroundStyle(Color.carbonAccent)
                                    Text("Copied to clipboard — paste it in the browser")
                                        .font(.carbonMono(.caption2))
                                        .foregroundStyle(Color.carbonTextTertiary)
                                } else {
                                    Text("Starting OAuth flow...")
                                        .font(.carbonSans(.subheadline))
                                        .foregroundStyle(Color.carbonTextSecondary)
                                }
                            }
                        }
                        .listRowBackground(Color.carbonSurface)
                    } else {
                        Button {
                            Task {
                                await registry?.codexAuth.startDeviceFlow()
                                if registry?.codexAuth.isAuthenticated == true {
                                    registry?.activeProviderId = provider.id
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Spacer()
                                Image(systemName: "person.badge.key")
                                    .font(.subheadline.weight(.medium))
                                Text("Sign in with OpenAI")
                                    .font(.carbonSans(.subheadline, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(Color.carbonBlack)
                            .padding(.vertical, 6)
                            .background(Color.carbonAccent)
                            .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                        }
                        .listRowBackground(Color.carbonSurface)
                    }

                    if let error = registry?.codexAuth.authError {
                        Text(error)
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonWarning)
                            .listRowBackground(Color.carbonSurface)
                    }
                } header: {
                    CarbonSectionHeader(title: "Or Sign In")
                }
            }

            // Model preview
            let previewModels = provider.sortedModels
            if !previewModels.isEmpty {
                Section {
                    ForEach(Array(previewModels.prefix(5))) { model in
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name)
                                    .font(.carbonSans(.subheadline))
                                    .foregroundStyle(Color.carbonText)
                                HStack(spacing: 5) {
                                    // Context window badge
                                    Label(model.displayContextWindow, systemImage: "text.word.spacing")
                                        .font(.carbonMono(.caption2))
                                        .foregroundStyle(Color.carbonTextTertiary)

                                    if model.reasoning {
                                        Text("REASON")
                                            .font(.carbonMono(.caption2, weight: .bold))
                                            .kerning(0.2)
                                            .foregroundStyle(Color.carbonAccent)
                                    }
                                    if model.toolCall {
                                        Text("TOOLS")
                                            .font(.carbonMono(.caption2, weight: .bold))
                                            .kerning(0.2)
                                            .foregroundStyle(Color.carbonSuccess)
                                    }
                                    if model.attachment {
                                        Image(systemName: "photo")
                                            .font(.caption2)
                                            .foregroundStyle(Color.carbonTextTertiary)
                                    }
                                }
                            }

                            Spacer()

                            Text(model.displayCost)
                                .font(.carbonMono(.caption2, weight: .medium))
                                .foregroundStyle(model.isFree ? Color.carbonSuccess : Color.carbonTextTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(model.isFree ? Color.carbonSuccess.opacity(0.1) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Color.carbonSurface)
                    }
                } header: {
                    CarbonSectionHeader(title: "Models")
                }
            }
        }
    }
}

// MARK: - Provider Key Edit View

struct ProviderKeyEditView: View {
    let provider: ModelsDevProvider
    let registry: ProviderRegistry?
    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyInput = ""
    @State private var isKeyVisible = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Text(String(provider.name.prefix(1)).uppercased())
                        .font(.carbonMono(.body, weight: .bold))
                        .foregroundStyle(Color.carbonAccent)
                        .frame(width: 40, height: 40)
                        .background(Color.carbonAccentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                            .font(.carbonSans(.headline, weight: .semibold))
                            .foregroundStyle(Color.carbonText)
                        if !provider.env.isEmpty {
                            Text(provider.env.joined(separator: " · "))
                                .font(.carbonMono(.caption2))
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.carbonSurface)
            }

            Section {
                HStack {
                    Group {
                        if isKeyVisible {
                            TextField("sk-...", text: $apiKeyInput)
                        } else {
                            SecureField("Paste your API key", text: $apiKeyInput)
                        }
                    }
                    .font(.carbonMono(.subheadline))
                    .foregroundStyle(Color.carbonText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundStyle(Color.carbonTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.carbonSurface)

                Button {
                    guard let registry, !apiKeyInput.isEmpty else { return }
                    registry.saveAPIKey(apiKeyInput, for: provider.id)
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "checkmark.circle")
                            .font(.subheadline.weight(.medium))
                        Text("Save")
                            .font(.carbonSans(.subheadline, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(apiKeyInput.isEmpty ? Color.carbonTextTertiary : Color.carbonBlack)
                    .padding(.vertical, 6)
                    .background(apiKeyInput.isEmpty ? Color.carbonElevated : Color.carbonAccent)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                }
                .disabled(apiKeyInput.isEmpty)
                .listRowBackground(Color.carbonSurface)
            } header: {
                CarbonSectionHeader(title: "API Key")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.carbonSurface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("EDIT KEY")
                    .font(.carbonMono(.caption, weight: .bold))
                    .kerning(2.5)
                    .foregroundStyle(Color.carbonText)
            }
        }
        .onAppear {
            // Pre-fill with existing key (masked)
            if let existing = registry?.loadAPIKey(for: provider.id) {
                apiKeyInput = existing
            }
        }
    }
}
