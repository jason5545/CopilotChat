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
        ProviderTransform.supportsReasoningEffort(model: nil, modelId: model, npm: nil, providerId: nil)
    }

    /// Check with full models.dev metadata.
    static func isSupported(model: String, modelInfo: ModelsDevModel?, npm: String?, providerId: String? = nil) -> Bool {
        ProviderTransform.supportsReasoningEffort(
            model: modelInfo, modelId: model, npm: npm, providerId: providerId)
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

// MARK: - App Mode

enum AppMode: String, CaseIterable, Codable, Sendable {
    case chat
    case coding

    var label: String {
        switch self {
        case .chat: "Chat"
        case .coding: "Coding"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left"
        case .coding: "chevron.left.forwardslash.chevron.right"
        }
    }

    var systemPrompt: String {
        switch self {
        case .chat:
            return "You are a helpful AI assistant. Respond in the user's language."
        case .coding:
            return "You are an expert coding assistant. You have access to file system tools to read, write, edit, and manage code files. When the user asks to view, create, edit, or modify code, use the appropriate file system tools. Be precise and thorough with code changes. Always maintain clean code style."
        }
    }
}

// MARK: - Tool Mode Availability

enum ToolModeAvailability {
    static let codingOnlyTools: Set<String> = [
        "list_files", "read_file", "write_file", "create_file", "delete_file", "move_file"
    ]

    static let alwaysAvailableTools: Set<String> = [
        "switch_mode", "tool_search"
    ]

    static func isAvailable(_ toolName: String, for mode: AppMode) -> Bool {
        if alwaysAvailableTools.contains(toolName) {
            return true
        }
        if codingOnlyTools.contains(toolName) {
            return mode == .coding
        }
        return true
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
    private static let appModeKey = "appMode"
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

    var appMode: AppMode {
        didSet {
            guard appMode != oldValue else { return }
            UserDefaults.standard.set(appMode.rawValue, forKey: Self.appModeKey)
        }
    }

    var effectiveSystemPrompt: String {
        appMode == .coding ? appMode.systemPrompt : systemPrompt
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

    private static let braveSearchKeychainKey = "brave-search-api-key"

    var braveSearchAPIKey: String {
        get { KeychainHelper.loadString(key: Self.braveSearchKeychainKey) ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(key: Self.braveSearchKeychainKey)
            } else {
                KeychainHelper.save(newValue, for: Self.braveSearchKeychainKey)
            }
        }
    }

    var hasBraveSearchAPIKey: Bool {
        KeychainHelper.loadString(key: Self.braveSearchKeychainKey) != nil
    }

    private static let mcpHeadersMigratedKey = "mcpHeadersMigratedToKeychain"

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
        self.appMode = {
            guard let raw = UserDefaults.standard.string(forKey: Self.appModeKey),
                  let mode = AppMode(rawValue: raw) else { return .chat }
            return mode
        }()

        // One-time migration: move MCP headers from UserDefaults JSON → Keychain
        if !UserDefaults.standard.bool(forKey: Self.mcpHeadersMigratedKey) {
            Self.migrateMCPHeadersToKeychain()
            UserDefaults.standard.set(true, forKey: Self.mcpHeadersMigratedKey)
        }

        self.mcpServers = Self.loadMCPServers()
        self.alwaysAllowedServers = Self.loadAlwaysAllowedServers()
        self.toolPermissionOverrides = Self.loadToolOverrides()
    }

    /// Migrate headers from legacy UserDefaults JSON (where headers was part of Codable) to Keychain.
    private static func migrateMCPHeadersToKeychain() {
        guard let data = UserDefaults.standard.data(forKey: mcpServersKey) else { return }

        // Decode raw JSON to extract headers that were previously included in the Codable payload
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for entry in entries {
            guard let idString = entry["id"] as? String,
                  let uuid = UUID(uuidString: idString),
                  let headers = entry["headers"] as? [String: String],
                  !headers.isEmpty else { continue }

            var config = MCPServerConfig(id: uuid, name: "", url: "", headers: headers)
            config.saveHeaders()
        }

        // Re-save without headers (the new Codable excludes them)
        if var servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            for i in servers.indices { servers[i].loadHeaders() }
            if let cleaned = try? JSONEncoder().encode(servers) {
                UserDefaults.standard.set(cleaned, forKey: mcpServersKey)
            }
        }
    }

    // MARK: - MCP Permissions

    /// Unified permission check: tool override > server level > session level > ask
    enum PermissionCheckResult {
        case allowed
        case denied
        case ask
    }

    func checkPermission(toolName: String, serverName: String) -> PermissionCheckResult {
        // 0. Plugin tools are always allowed
        if PluginRegistry.shared.allPluginTools().contains(where: { $0.name == toolName }) {
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
        if let pluginTool = PluginRegistry.shared.allPluginTools().first(where: { $0.name == toolName }) {
            return pluginTool.serverName
        }
        return mcpTools.first(where: { $0.name == toolName })?.serverName
    }

    func toolsForServer(_ serverName: String) -> [MCPTool] {
        mcpTools.filter { $0.serverName == serverName }
    }

    // MARK: - MCP Server Management

    func addServer(_ server: MCPServerConfig) {
        server.saveHeaders()
        mcpServers.append(server)
    }

    func removeServer(at offsets: IndexSet) {
        let idsToRemove = offsets.map { mcpServers[$0].id }
        for id in idsToRemove {
            mcpClients.removeValue(forKey: id)
            mcpConnectionErrors.removeValue(forKey: id)
            MCPServerConfig.deleteHeaders(for: id)
        }
        mcpServers.remove(atOffsets: offsets)
        refreshToolsList()
    }

    func updateServer(_ server: MCPServerConfig) {
        if let index = mcpServers.firstIndex(where: { $0.id == server.id }) {
            server.saveHeaders()
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
              var servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        // Hydrate headers from Keychain
        for i in servers.indices {
            servers[i].loadHeaders()
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
