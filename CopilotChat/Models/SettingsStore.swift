import Foundation
import Observation

// MARK: - Reasoning Effort

enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case off
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var label: String {
        switch self {
        case .off: "Off"
        case .none: "None"
        case .minimal: "Min"
        case .low: "Low"
        case .medium: "Med"
        case .high: "High"
        case .xhigh: "XHigh"
        case .max: "Max"
        }
    }

    /// Check if the model supports reasoning effort.
    /// Uses models.dev data when available, otherwise falls back to heuristics.
    static func isSupported(model: String) -> Bool {
        ProviderTransform.supportsReasoningEffort(model: nil, modelId: model, npm: nil)
    }

    /// Check with full models.dev metadata.
    static func isSupported(model: String, modelInfo: ModelsDevModel?, npm: String?) -> Bool {
        ProviderTransform.supportsReasoningEffort(model: modelInfo, modelId: model, npm: npm)
    }
}

// MARK: - Tool Access Mode

enum ToolAccessMode: String, CaseIterable, Codable, Sendable {
    case alwaysLoaded
    case loadWhenNeeded

    var label: String {
        switch self {
        case .alwaysLoaded: "Tools always loaded"
        case .loadWhenNeeded: "Load tools when needed"
        }
    }

    var description: String {
        switch self {
        case .alwaysLoaded: "All tool schemas sent in every request. Uses more context window."
        case .loadWhenNeeded: "MCP tools loaded on demand via tool search. Saves context window."
        }
    }
}

@Observable
@MainActor
final class SettingsStore {
    private static let modelsKey = "selectedModel"
    private static let mcpServersKey = "mcpServers"
    private static let alwaysAllowedKey = "mcpAlwaysAllowedServers"
    private static let toolOverridesKey = "mcpToolPermissionOverrides"
    private static let reasoningEffortKey = "reasoningEffort"
    private static let systemPromptKey = "systemPrompt"
    private static let toolAccessModeKey = "toolAccessMode"
    private static let defaultModel = "claude-sonnet-4-6"
    static let defaultSystemPrompt = "You are a helpful AI assistant. Respond in the user's language."

    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: Self.modelsKey) }
    }

    var reasoningEffort: ReasoningEffort {
        didSet {
            guard reasoningEffort != oldValue else { return }
            UserDefaults.standard.set(reasoningEffort.rawValue, forKey: Self.reasoningEffortKey)
        }
    }

    var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Self.systemPromptKey) }
    }

    var toolAccessMode: ToolAccessMode {
        didSet {
            guard toolAccessMode != oldValue else { return }
            UserDefaults.standard.set(toolAccessMode.rawValue, forKey: Self.toolAccessModeKey)
        }
    }

    var mcpServers: [MCPServerConfig] {
        didSet { saveMCPServers() }
    }

    // Live MCP clients keyed by server config ID
    var mcpClients: [UUID: MCPClient] = [:]
    var mcpTools: [MCPTool] = []
    var mcpConnectionErrors: [UUID: String] = [:]

    // MCP Permission state
    var alwaysAllowedServers: Set<String> {
        didSet { saveAlwaysAllowedServers() }
    }
    var toolPermissionOverrides: [String: ToolPermissionOverride] {
        didSet { saveToolOverrides() }
    }
    var sessionAllowedServers: Set<String> = []

    // MARK: - API Keys

    var braveSearchAPIKey: String {
        get { KeychainHelper.loadString(key: BuiltInTools.braveSearchKeychainKey) ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(key: BuiltInTools.braveSearchKeychainKey)
            } else {
                KeychainHelper.save(newValue, for: BuiltInTools.braveSearchKeychainKey)
            }
            BuiltInTools.invalidateToolsCache()
        }
    }

    var hasBraveSearchAPIKey: Bool {
        KeychainHelper.loadString(key: BuiltInTools.braveSearchKeychainKey) != nil
    }

    init() {
        self.selectedModel = UserDefaults.standard.string(forKey: Self.modelsKey) ?? Self.defaultModel
        self.reasoningEffort = {
            guard let raw = UserDefaults.standard.string(forKey: Self.reasoningEffortKey),
                  let effort = ReasoningEffort(rawValue: raw) else { return .high }
            return effort
        }()
        self.systemPrompt = UserDefaults.standard.string(forKey: Self.systemPromptKey) ?? Self.defaultSystemPrompt
        self.toolAccessMode = {
            guard let raw = UserDefaults.standard.string(forKey: Self.toolAccessModeKey),
                  let mode = ToolAccessMode(rawValue: raw) else { return .alwaysLoaded }
            return mode
        }()
        self.mcpServers = Self.loadMCPServers()
        self.alwaysAllowedServers = Self.loadAlwaysAllowedServers()
        self.toolPermissionOverrides = Self.loadToolOverrides()
    }

    // MARK: - MCP Permissions

    /// Unified permission check: tool override > server level > session level > ask
    enum PermissionCheckResult {
        case allowed
        case denied
        case ask
    }

    func checkPermission(toolName: String, serverName: String) -> PermissionCheckResult {
        // 0. Built-in tools are always allowed
        if BuiltInTools.isBuiltIn(toolName) {
            return .allowed
        }
        // 1. Tool-level override takes priority
        if let toolOverride = toolPermissionOverrides[toolName] {
            return toolOverride == .alwaysAllow ? .allowed : .denied
        }
        // 2. Server-level persistent or session permission
        if alwaysAllowedServers.contains(serverName) || sessionAllowedServers.contains(serverName) {
            return .allowed
        }
        // 3. Need to ask
        return .ask
    }

    func allowServerAlways(_ serverName: String) {
        alwaysAllowedServers.insert(serverName)
    }

    func allowServerForSession(_ serverName: String) {
        sessionAllowedServers.insert(serverName)
    }

    func clearSessionPermissions() {
        sessionAllowedServers.removeAll()
    }

    func revokeAlwaysAllow(_ serverName: String) {
        alwaysAllowedServers.remove(serverName)
    }

    func setToolOverride(_ toolName: String, _ override: ToolPermissionOverride?) {
        toolPermissionOverrides[toolName] = override
    }

    func resetAllPermissions() {
        alwaysAllowedServers.removeAll()
        toolPermissionOverrides.removeAll()
        sessionAllowedServers.removeAll()
    }

    func serverNameForTool(_ toolName: String) -> String? {
        if BuiltInTools.isBuiltIn(toolName) {
            return BuiltInTools.serverName
        }
        return mcpTools.first(where: { $0.name == toolName })?.serverName
    }

    func toolsForServer(_ serverName: String) -> [MCPTool] {
        mcpTools.filter { $0.serverName == serverName }
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

    private func saveAlwaysAllowedServers() {
        let array = Array(alwaysAllowedServers)
        UserDefaults.standard.set(array, forKey: Self.alwaysAllowedKey)
    }

    private static func loadAlwaysAllowedServers() -> Set<String> {
        guard let array = UserDefaults.standard.stringArray(forKey: alwaysAllowedKey) else {
            return []
        }
        return Set(array)
    }

    private func saveToolOverrides() {
        if let data = try? JSONEncoder().encode(toolPermissionOverrides) {
            UserDefaults.standard.set(data, forKey: Self.toolOverridesKey)
        }
    }

    private static func loadToolOverrides() -> [String: ToolPermissionOverride] {
        guard let data = UserDefaults.standard.data(forKey: toolOverridesKey),
              let overrides = try? JSONDecoder().decode([String: ToolPermissionOverride].self, from: data) else {
            return [:]
        }
        return overrides
    }
}
