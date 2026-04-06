import SwiftUI

/// Standalone MCP settings view for deeper navigation if needed.
/// Most MCP settings are handled inline in SettingsView.
struct MCPSettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore

    @State private var showAddServer = false

    var body: some View {
        List {
            Section {
                ForEach(settingsStore.mcpServers) { server in
                    NavigationLink {
                        MCPServerDetailView(server: server)
                    } label: {
                        serverRow(server)
                    }
                }
                .onDelete { offsets in
                    settingsStore.removeServer(at: offsets)
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("MCP servers provide tools that the AI can use during conversations.")
            }

            Section("Connected Tools") {
                if settingsStore.mcpTools.isEmpty {
                    Text("No tools available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settingsStore.mcpTools) { tool in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "wrench.and.screwdriver")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                                Text(tool.name)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(tool.serverName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("MCP Servers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddServer) {
            MCPServerEditView(server: nil) { server in
                settingsStore.addServer(server)
                Task { await settingsStore.connectServer(server) }
            }
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !server.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if settingsStore.mcpConnectionErrors[server.id] != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else if settingsStore.mcpClients[server.id] != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
    }
}
