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
                    .listRowBackground(Color.carbonSurface)
                }
                .onDelete { offsets in
                    settingsStore.removeServer(at: offsets)
                }
            } header: {
                CarbonSectionHeader(title: "Servers")
            } footer: {
                Text("MCP servers provide tools that the AI can use during conversations.")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }

            Section {
                if settingsStore.mcpTools.isEmpty {
                    Text("No tools available")
                        .font(.carbonSans(.subheadline))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .listRowBackground(Color.carbonSurface)
                } else {
                    ForEach(settingsStore.mcpTools) { tool in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: "wrench.and.screwdriver")
                                    .foregroundStyle(Color.carbonAccent)
                                    .font(.caption2)
                                Text(tool.name)
                                    .font(.carbonMono(.caption, weight: .semibold))
                                    .foregroundStyle(Color.carbonText)
                                Spacer()
                                Text(tool.serverName)
                                    .font(.carbonMono(.caption2))
                                    .foregroundStyle(Color.carbonTextTertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.carbonElevated)
                                    .clipShape(Capsule())
                            }
                            Text(tool.description)
                                .font(.carbonSans(.caption))
                                .foregroundStyle(Color.carbonTextSecondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Color.carbonSurface)
                    }
                }
            } header: {
                CarbonSectionHeader(title: "Connected Tools")
            }

        }
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .navigationTitle("MCP Servers")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.carbonAccent)
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
            if !server.isEnabled {
                Text("OFF")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .foregroundStyle(Color.carbonTextTertiary)
                    .kerning(0.4)
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
}
