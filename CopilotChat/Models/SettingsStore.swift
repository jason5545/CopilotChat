import Foundation
import Observation

@Observable
@MainActor
final class SettingsStore {
    private static let modelsKey = "selectedModel"
    private static let mcpServersKey = "mcpServers"
    private static let defaultModel = "claude-sonnet-4-6"

    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: Self.modelsKey) }
    }

    var mcpServers: [MCPServerConfig] {
        didSet { saveMCPServers() }
    }

    // Live MCP clients keyed by server config ID
    var mcpClients: [UUID: MCPClient] = [:]
    var mcpTools: [MCPTool] = []
    var mcpConnectionErrors: [UUID: String] = [:]

    init() {
        self.selectedModel = UserDefaults.standard.string(forKey: Self.modelsKey) ?? Self.defaultModel
        self.mcpServers = Self.loadMCPServers()
    }

    // MARK: - MCP Server Management

    func addServer(_ server: MCPServerConfig) {
        mcpServers.append(server)
    }

    func removeServer(at offsets: IndexSet) {
        let idsToRemove = offsets.map { mcpServers[$0].id }
        for id in idsToRemove {
            mcpClients.removeValue(forKey: id)
            mcpConnectionErrors.removeValue(forKey: id)
        }
        mcpServers.remove(atOffsets: offsets)
        refreshToolsList()
    }

    func updateServer(_ server: MCPServerConfig) {
        if let index = mcpServers.firstIndex(where: { $0.id == server.id }) {
            mcpServers[index] = server
            // Reconnect if enabled
            if server.isEnabled {
                Task { await connectServer(server) }
            } else {
                mcpClients.removeValue(forKey: server.id)
                mcpConnectionErrors.removeValue(forKey: server.id)
                refreshToolsList()
            }
        }
    }

    // MARK: - MCP Connections

    func connectAllServers() async {
        await withTaskGroup(of: Void.self) { group in
            for server in mcpServers where server.isEnabled {
                group.addTask { [self] in
                    await self.connectServer(server)
                }
            }
        }
    }

    func connectServer(_ server: MCPServerConfig) async {
        let client = MCPClient(config: server)
        mcpClients[server.id] = client
        mcpConnectionErrors.removeValue(forKey: server.id)

        do {
            try await client.connect()
            refreshToolsList()
        } catch {
            mcpConnectionErrors[server.id] = error.localizedDescription
        }
    }

    func callTool(name: String, argumentsJSON: String) async throws -> String {
        // Find which client has this tool
        for (_, client) in mcpClients {
            let tools = await client.tools
            if tools.contains(where: { $0.name == name }) {
                return try await client.callTool(name: name, argumentsJSON: argumentsJSON)
            }
        }
        throw MCPClient.MCPError.invalidResponse
    }

    private func refreshToolsList() {
        Task {
            var allTools: [MCPTool] = []
            for (_, client) in mcpClients {
                let tools = await client.tools
                allTools.append(contentsOf: tools)
            }
            mcpTools = allTools
        }
    }

    // MARK: - Persistence

    private func saveMCPServers() {
        if let data = try? JSONEncoder().encode(mcpServers) {
            UserDefaults.standard.set(data, forKey: Self.mcpServersKey)
        }
    }

    private static func loadMCPServers() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: mcpServersKey),
              let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return servers
    }
}
