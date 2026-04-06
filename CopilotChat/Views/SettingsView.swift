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
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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
        Section("Account") {
            if authManager.isAuthenticated {
                HStack(spacing: 12) {
                    if let url = authManager.avatarUrl, let imageURL = URL(string: url) {
                        AsyncImage(url: imageURL) { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.circle.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading) {
                        Text(authManager.username ?? "GitHub User")
                            .font(.headline)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer()
                }

                Button("Sign Out", role: .destructive) {
                    authManager.signOut()
                }
            } else if authManager.isAuthenticating {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ProgressView()
                        Text("Waiting for authorization...")
                            .font(.subheadline)
                    }

                    if let code = authManager.deviceFlowUserCode {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enter this code on GitHub:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(code)
                                .font(.system(.title, design: .monospaced))
                                .fontWeight(.bold)
                                .textSelection(.enabled)
                        }

                        if let urlString = authManager.deviceFlowVerificationURL,
                           let url = URL(string: urlString) {
                            Link("Open GitHub", destination: url)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    Task { await authManager.startDeviceFlow() }
                } label: {
                    Label("Sign in with GitHub", systemImage: "person.badge.key")
                }

                if let error = authManager.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        Section("Model") {
            @Bindable var store = settingsStore

            if copilotService.availableModels.isEmpty {
                HStack {
                    Text(settingsStore.selectedModel)
                    Spacer()
                    if authManager.isAuthenticated {
                        Button("Refresh") {
                            Task { await copilotService.fetchModels() }
                        }
                        .font(.caption)
                    }
                }
            } else {
                Picker("Model", selection: $store.selectedModel) {
                    ForEach(copilotService.availableModels) { model in
                        Text(model.displayName)
                            .tag(model.id)
                    }
                }
            }
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .font(.headline)
                            Text(server.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        serverStatusIndicator(for: server)
                    }
                }
            }
            .onDelete { offsets in
                settingsStore.removeServer(at: offsets)
            }

            Button {
                showAddMCPServer = true
            } label: {
                Label("Add MCP Server", systemImage: "plus")
            }
        } header: {
            Text("MCP Servers")
        } footer: {
            if !settingsStore.mcpTools.isEmpty {
                Text("\(settingsStore.mcpTools.count) tools available")
            }
        }
    }

    private func serverStatusIndicator(for server: MCPServerConfig) -> some View {
        Group {
            if !server.isEnabled {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            } else if let error = settingsStore.mcpConnectionErrors[server.id] {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            } else if settingsStore.mcpClients[server.id] != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }
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
            Section("Server") {
                TextField("Name", text: $name)
                TextField("URL", text: $url)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Toggle("Enabled", isOn: $isEnabled)
            }

            Section {
                TextEditor(text: $headersText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Headers")
            } footer: {
                Text("One per line: Header-Name: value")
            }

            if let error = settingsStore.mcpConnectionErrors[server.id] {
                Section("Error") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Save") {
                    let updated = MCPServerConfig(
                        id: server.id,
                        name: name,
                        url: url,
                        headers: Self.textToHeaders(headersText),
                        isEnabled: isEnabled
                    )
                    settingsStore.updateServer(updated)
                    dismiss()
                }
                .disabled(name.isEmpty || url.isEmpty)

                Button("Reconnect") {
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
                }
            }
        }
        .navigationTitle(server.name)
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
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Toggle("Enabled", isOn: $isEnabled)
                }

                Section {
                    TextEditor(text: $headersText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Headers")
                } footer: {
                    Text("One per line: Header-Name: value")
                }
            }
            .navigationTitle("Add MCP Server")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let newServer = MCPServerConfig(
                            name: name,
                            url: url,
                            headers: MCPServerDetailView.textToHeaders(headersText),
                            isEnabled: isEnabled
                        )
                        onSave(newServer)
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}
