import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CopilotService.self) private var copilotService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAddMCPServer = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                modelSection
                mcpSection
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

    // MARK: - Model Section

    private var modelSection: some View {
        Section {
            @Bindable var store = settingsStore

            if copilotService.availableModels.isEmpty {
                HStack {
                    Text(settingsStore.selectedModel)
                        .font(.carbonMono(.subheadline))
                        .foregroundStyle(Color.carbonText)
                    Spacer()
                    if authManager.isAuthenticated {
                        Button {
                            Task { await copilotService.fetchModels() }
                        } label: {
                            Text("REFRESH")
                                .font(.carbonMono(.caption2, weight: .bold))
                                .kerning(0.6)
                                .foregroundStyle(Color.carbonAccent)
                        }
                    }
                }
                .listRowBackground(Color.carbonSurface)
            } else {
                Picker("Model", selection: $store.selectedModel) {
                    ForEach(copilotService.availableModels) { model in
                        Text(model.displayName)
                            .font(.carbonSans(.subheadline))
                            .tag(model.id)
                    }
                }
                .tint(Color.carbonAccent)
                .listRowBackground(Color.carbonSurface)
            }
        } header: {
            CarbonSectionHeader(title: "Model")
        }
    }

    // MARK: - MCP Section

    private var mcpSection: some View {
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
        } header: {
            CarbonSectionHeader(title: "MCP Servers")
        } footer: {
            if !settingsStore.mcpTools.isEmpty {
                Text("\(settingsStore.mcpTools.count) tools available")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
        }
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
