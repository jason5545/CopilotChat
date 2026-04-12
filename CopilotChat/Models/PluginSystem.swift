import Foundation
import UIKit

// ===== Tool Result =====

struct ToolResult: Sendable {
    let text: String
    let imageData: Data?

    init(text: String, imageData: Data? = nil) {
        self.text = text
        self.imageData = imageData
    }
}

// ===== Plugin Errors =====

enum PluginError: LocalizedError {
    case unknownTool(String)
    case pluginLoadFailed(String)
    case pluginDisabled
    case apiError(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .pluginLoadFailed(let id): "Failed to load plugin: \(id)"
        case .pluginDisabled: "Plugin is disabled"
        case .apiError(let msg): "API error: \(msg)"
        case .invalidArguments(let msg): "Invalid arguments: \(msg)"
        }
    }
}

// ===== Plugin System =====

struct PluginInput: Sendable {
    let deviceId: String
    let platform: String
    let version: String

    init(deviceId: String, platform: String = "ios", version: String = "1.0.0") {
        self.deviceId = deviceId
        self.platform = platform
        self.version = version
    }
}

protocol Plugin: Sendable {
    var id: String { get }
    var name: String { get }
    var version: String { get }

    @MainActor
    func configure(with input: PluginInput) async throws -> PluginHooks
}

struct AuthHook: Sendable {
    let providerId: String
    let isAuthenticated: @MainActor @Sendable () -> Bool
    let isAuthenticating: @MainActor @Sendable () -> Bool
    let authError: @MainActor @Sendable () -> String?
    let deviceUserCode: @MainActor @Sendable () -> String?
    let startDeviceFlow: @MainActor @Sendable () async -> Void
    let signOut: @MainActor @Sendable () -> Void
    let validAccessToken: @Sendable () async throws -> String
    let accountId: @MainActor @Sendable () -> String?
}

struct PluginHooks: Sendable {
    let tools: [MCPTool]
    let onExecute: (@Sendable (String, String) async throws -> ToolResult)?
    let onExecuteStreaming: (@Sendable (String, String, @escaping @Sendable (String) -> Void) async throws -> ToolResult)?
    let auth: AuthHook?

    init(
        tools: [MCPTool] = [],
        onExecute: (@Sendable (String, String) async throws -> ToolResult)? = nil,
        onExecuteStreaming: (@Sendable (String, String, @escaping @Sendable (String) -> Void) async throws -> ToolResult)? = nil,
        auth: AuthHook? = nil
    ) {
        self.tools = tools
        self.onExecute = onExecute
        self.onExecuteStreaming = onExecuteStreaming
        self.auth = auth
    }
}

// ===== Plugin Registry =====

@Observable
@MainActor
final class PluginRegistry {
    static let shared = PluginRegistry()

    func allTools(for mode: AppMode) -> [MCPTool] {
        var result = baseTools.filter { tool in
            ToolModeAvailability.isAvailable(tool.name, for: mode)
        }
        for (pluginId, hooks) in hooksMap {
            if enabledPluginIds.contains(pluginId) {
                let filteredTools = hooks.tools.filter { tool in
                    ToolModeAvailability.isAvailable(tool.name, for: mode)
                }
                result.append(contentsOf: filteredTools)
            }
        }
        return result
    }

    func allPluginTools() -> [MCPTool] {
        var result = baseTools
        for (pluginId, hooks) in hooksMap {
            if enabledPluginIds.contains(pluginId) {
                result.append(contentsOf: hooks.tools)
            }
        }
        return result
    }

    private var baseTools: [MCPTool] = [
        MCPTool(
            name: "tool_search",
            description: "Search for available MCP tools by name or keyword. Returns matching tools with their full schemas so they can be called in subsequent requests. Use this when you need a tool that isn't directly available yet.",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "query": [
                        "type": "string",
                        "description": "Tool name (exact match) or keyword to search tool names and descriptions",
                    ] as [String: Any],
                    "max_results": [
                        "type": "integer",
                        "description": "Maximum number of results to return (default: 5)",
                    ] as [String: Any],
                ] as [String: Any]),
                "required": AnyCodable(["query"]),
            ],
            serverName: "Built-in"
        ),
    ]

    func searchTools(query: String, maxResults: Int = 5, in availableTools: [MCPTool]) -> (text: String, matchedNames: [String]) {
        let q = query.lowercased()

        if let exact = availableTools.first(where: { $0.name.lowercased() == q }) {
            return (formatToolResult(exact), [exact.name])
        }

        let nameMatches = availableTools.filter { $0.name.lowercased().contains(q) }
        let nameMatchNames = Set(nameMatches.map(\.name))
        let descMatches = availableTools.filter { tool in
            !nameMatchNames.contains(tool.name) &&
            tool.description.lowercased().contains(q)
        }

        let combined = Array((nameMatches + descMatches).prefix(maxResults))

        if combined.isEmpty {
            return ("No tools found matching \"\(query)\". Available tools: \(availableTools.map(\.name).joined(separator: ", "))", [])
        }

        let lines = combined.map { formatToolResult($0) }
        let text = "Found \(combined.count) tool(s):\n\n" + lines.joined(separator: "\n\n---\n\n")
        return (text, combined.map(\.name))
    }

    private func formatToolResult(_ tool: MCPTool) -> String {
        var result = "**\(tool.name)** (server: \(tool.serverName))\n\(tool.description)"
        if let schema = tool.inputSchema {
            if let data = try? JSONSerialization.data(withJSONObject: schema.mapValues(\.value), options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                result += "\n\nParameters:\n```json\n\(json)\n```"
            }
        }
        return result
    }

    var registeredPlugins: [any Plugin] {
        Array(plugins.values)
    }

    var pluginCount: Int {
        plugins.count
    }

    private var plugins: [String: any Plugin] = [:]
    private var toolHandlers: [String: @Sendable (String) async throws -> ToolResult] = [:]
    private var toolStreamingHandlers: [String: @Sendable (String, @escaping @Sendable (String) -> Void) async throws -> ToolResult] = [:]
    private var hooksMap: [String: PluginHooks] = [:]
    private var enabledPluginIds: Set<String> = []

    private init() {}

    @discardableResult
    func register<P: Plugin>(_ plugin: P) -> String {
        plugins[plugin.id] = plugin
        enabledPluginIds.insert(plugin.id)
        return plugin.id
    }

    func registerExternalPlugin(pluginId: String, hooks: PluginHooks, toolNames: [String]) {
        hooksMap[pluginId] = hooks
        for toolName in toolNames {
            toolHandlers["\(pluginId).\(toolName)"] = { args in
                try await hooks.onExecute?(toolName, args) ?? ToolResult(text: "Plugin not available")
            }
            if let streaming = hooks.onExecuteStreaming {
                toolStreamingHandlers["\(pluginId).\(toolName)"] = { args, progress in
                    try await streaming(toolName, args, progress)
                }
            }
        }
        enabledPluginIds.insert(pluginId)
    }

    func isEnabled(pluginId: String) -> Bool {
        enabledPluginIds.contains(pluginId)
    }

    func setEnabled(pluginId: String, enabled: Bool) {
        if enabled {
            enabledPluginIds.insert(pluginId)
        } else {
            enabledPluginIds.remove(pluginId)
        }
    }

    // MARK: - Plugin Loading

    func loadPlugins() async {
        await registerBuiltInPlugins()
    }

    func loadPlugins(authManager: AuthManager, settingsStore: SettingsStore, providerRegistry: ProviderRegistry) async {
        await registerBuiltInPlugins()

        let codexPlugin = CodexPlugin()
        await registerAndConfigure(codexPlugin)

        let taskPlugin = TaskPlugin(authManager: authManager, settingsStore: settingsStore, providerRegistry: providerRegistry)
        await registerAndConfigure(taskPlugin)
    }

    private func registerBuiltInPlugins() async {
        let plugins: [any Plugin] = [
            BrowserPlugin(),
            BraveSearchPlugin(),
            FileSystemPlugin(),
            GitHubPlugin(),
        ]
        for plugin in plugins {
            await registerAndConfigure(plugin)
        }
    }

    /// Configures a plugin, registers its tool/streaming handlers, and enables it.
    private func registerAndConfigure(_ plugin: any Plugin) async {
        let input = PluginInput(deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown")
        if let hooks = try? await plugin.configure(with: input) {
            hooksMap[plugin.id] = hooks
            registerToolHandlers(pluginId: plugin.id, hooks: hooks)
        }
        plugins[plugin.id] = plugin
        enabledPluginIds.insert(plugin.id)
    }

    /// Registers tool and streaming handlers for a plugin's hooks.
    private func registerToolHandlers(pluginId: String, hooks: PluginHooks) {
        for tool in hooks.tools {
            let toolName = tool.name
            toolHandlers["\(pluginId).\(toolName)"] = { args in
                try await hooks.onExecute?(toolName, args) ?? ToolResult(text: "Plugin not available")
            }
            if let streaming = hooks.onExecuteStreaming {
                toolStreamingHandlers["\(pluginId).\(toolName)"] = { args, progress in
                    try await streaming(toolName, args, progress)
                }
            }
        }
    }

    func executeTool(pluginId: String, toolName: String, argumentsJSON: String) async throws -> ToolResult {
        guard enabledPluginIds.contains(pluginId) else {
            throw PluginError.pluginDisabled
        }
        guard let handler = toolHandlers["\(pluginId).\(toolName)"] else {
            throw PluginError.unknownTool(toolName)
        }
        return try await handler(argumentsJSON)
    }

    func executeToolStreaming(
        pluginId: String,
        toolName: String,
        argumentsJSON: String,
        progressHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        guard enabledPluginIds.contains(pluginId) else {
            throw PluginError.pluginDisabled
        }
        guard let handler = toolStreamingHandlers["\(pluginId).\(toolName)"] else {
            return try await executeTool(pluginId: pluginId, toolName: toolName, argumentsJSON: argumentsJSON)
        }
        return try await handler(argumentsJSON, progressHandler)
    }

    func plugin(for id: String) -> (any Plugin)? {
        plugins[id]
    }

    func hooks(for id: String) -> PluginHooks? {
        hooksMap[id]
    }

    func authHook(for providerId: String) -> AuthHook? {
        for (_, hooks) in hooksMap {
            if let auth = hooks.auth, auth.providerId == providerId {
                return auth
            }
        }
        return nil
    }

    var codexAuth: OpenAICodexAuth? {
        (plugins["com.copilotchat.codex"] as? CodexPlugin)?.auth
    }

    var hooksMapSnapshot: [String: PluginHooks] {
        hooksMap
    }

    enum PluginError: LocalizedError {
        case unknownTool(String)
        case pluginLoadFailed(String)
        case pluginDisabled

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown tool: \(name)"
            case .pluginLoadFailed(let id): "Failed to load plugin: \(id)"
            case .pluginDisabled: "Plugin is disabled"
            }
        }
    }
}

// ===== Browser Plugin (POC) =====

final class BrowserPlugin: Plugin {
    let id = "com.copilotchat.browser"
    let name = "Browser"
    let version = "1.0.0"

    @MainActor
    func configure(with input: PluginInput) async throws -> PluginHooks {
        let tools = [
            MCPTool(
                name: "web_fetch",
                description: "Fetch the text content of a web page. Provide a URL and receive the page's text content with HTML tags stripped.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "url": [
                            "type": "string",
                            "description": "The URL of the web page to fetch (must start with http:// or https://)",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["url"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "web_screenshot",
                description: "Take a visual screenshot of a web page. Returns an image of the rendered page.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "url": [
                            "type": "string",
                            "description": "The URL of the web page to screenshot (must start with http:// or https://)",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["url"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "curl_request",
                description: "Make an HTTP request and return the response body, status code, and headers. Supports GET, POST, PUT, DELETE, PATCH, HEAD, and OPTIONS methods.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "url": [
                            "type": "string",
                            "description": "The URL to request (must start with http:// or https://)",
                        ] as [String: Any],
                        "method": [
                            "type": "string",
                            "description": "HTTP method: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS. Default: GET.",
                            "enum": ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"],
                        ] as [String: Any],
                        "headers": [
                            "type": "object",
                            "description": "HTTP headers as key-value pairs.",
                        ] as [String: Any],
                        "body": [
                            "type": "string",
                            "description": "Request body (for POST, PUT, PATCH).",
                        ] as [String: Any],
                        "timeout": [
                            "type": "integer",
                            "description": "Timeout in seconds (default: 30).",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["url"]),
                ],
                serverName: name
            ),
            MCPTool(
                name: "wget_download",
                description: "Download a file from a URL and save it directly to the workspace. Unlike curl_request, this has no body size limit and saves the raw response to disk.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "url": [
                            "type": "string",
                            "description": "The URL to download from (must start with http:// or https://)",
                        ] as [String: Any],
                        "save_path": [
                            "type": "string",
                            "description": "The file path within the workspace to save the downloaded content. If omitted, uses the filename from the URL.",
                        ] as [String: Any],
                        "headers": [
                            "type": "object",
                            "description": "HTTP headers as key-value pairs.",
                        ] as [String: Any],
                        "timeout": [
                            "type": "integer",
                            "description": "Timeout in seconds (default: 60).",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["url"]),
                ],
                serverName: name
            ),
        ]

        return PluginHooks(tools: tools) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        }
    }

    @MainActor
    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        switch name {
        case "web_fetch":
            guard let url = parseURL(from: argumentsJSON) else {
                throw WebFetchService.WebFetchError.invalidURL(argumentsJSON)
            }
            let text = try await WebFetchService.fetch(url: url)
            return ToolResult(text: text)
        case "web_screenshot":
            guard let url = parseURL(from: argumentsJSON) else {
                throw WebFetchService.WebFetchError.invalidURL(argumentsJSON)
            }
            let (desc, imageData) = try await WebFetchService.screenshot(url: url)
            return ToolResult(text: desc, imageData: imageData)
        case "curl_request":
            return try await executeCurlRequest(argumentsJSON: argumentsJSON)
        case "wget_download":
            return try await executeWgetDownload(argumentsJSON: argumentsJSON)
        default:
            throw PluginRegistry.PluginError.unknownTool(name)
        }
    }

    private func parseURL(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = args["url"] as? String else {
            return nil
        }
        return url
    }

    @MainActor
    private func executeCurlRequest(argumentsJSON: String) async throws -> ToolResult {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
            throw PluginError.invalidArguments("curl_request requires a valid 'url' string argument")
        }

        let method = (args["method"] as? String ?? "GET").uppercased()
        let headers = args["headers"] as? [String: String] ?? [:]
        let body = args["body"] as? String
        let timeout = TimeInterval(args["timeout"] as? Int ?? 30)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body {
            request.httpBody = body.data(using: .utf8)
            if headers["Content-Type"] == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return ToolResult(text: "Error: Non-HTTP response received")
        }

        var output = "HTTP \(httpResponse.statusCode)\n"

        let responseHeaders = httpResponse.allHeaderFields
            .sorted { ($0.key as? String ?? "") < ($1.key as? String ?? "") }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        output += responseHeaders + "\n\n"

        let responseBody = String(data: responseData, encoding: .utf8)
            ?? String(data: responseData, encoding: .ascii)
            ?? "(binary data, \(responseData.count) bytes)"

        if responseBody.count > 10_000 {
            output += String(responseBody.prefix(10_000)) + "\n\n(truncated at 10000 chars)"
        } else {
            output += responseBody
        }

        return ToolResult(text: output)
    }

    @MainActor
    private func executeWgetDownload(argumentsJSON: String) async throws -> ToolResult {
        let workspaceManager = WorkspaceManager.shared

        guard workspaceManager.hasWorkspace else {
            return ToolResult(text: "No workspace selected. Please select a project folder first.")
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
            throw PluginError.invalidArguments("wget_download requires a valid 'url' string argument")
        }

        let headers = args["headers"] as? [String: String] ?? [:]
        let timeout = TimeInterval(args["timeout"] as? Int ?? 60)

        let savePath: String
        if let customPath = args["save_path"] as? String, !customPath.isEmpty {
            savePath = customPath
        } else {
            savePath = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        }

        guard let saveURL = WorkspaceManager.shared.resolvePathPublic(savePath) else {
            return ToolResult(text: "Invalid save path: \(savePath)")
        }

        let parentDir = saveURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return ToolResult(text: "Error: Non-HTTP response received")
        }

        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            let body = String(data: responseData, encoding: .utf8) ?? "(binary, \(responseData.count) bytes)"
            return ToolResult(text: "HTTP \(httpResponse.statusCode)\n\(body)")
        }

        try responseData.write(to: saveURL, options: .atomic)

        let byteCount = ByteCountFormatter.string(fromByteCount: Int64(responseData.count), countStyle: .file)
        let mimeType = httpResponse.mimeType ?? "unknown"
        return ToolResult(text: "Downloaded \(urlString)\nSaved to: \(savePath)\nSize: \(byteCount)\nType: \(mimeType)")
    }
}

// ===== Brave Search Plugin =====

final class BraveSearchPlugin: Plugin {
    let id = "com.copilotchat.brave-search"
    let name = "Brave Search"
    let version = "1.0.0"

    @MainActor
    func configure(with input: PluginInput) async throws -> PluginHooks {
        let tools = [
            MCPTool(
                name: "brave_web_search",
                description: "Search the web using Brave Search. Returns web search results including titles, URLs, and descriptions.",
                inputSchema: [
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "query": [
                            "type": "string",
                            "description": "The search query",
                        ] as [String: Any],
                        "count": [
                            "type": "integer",
                            "description": "Number of results to return (default: 5, max: 20)",
                        ] as [String: Any],
                    ] as [String: Any]),
                    "required": AnyCodable(["query"]),
                ],
                serverName: name
            ),
        ]

        return PluginHooks(tools: tools) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        }
    }

    @MainActor
    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        switch name {
        case "brave_web_search":
            let text = try await executeBraveSearch(argumentsJSON: argumentsJSON)
            return ToolResult(text: text)
        default:
            throw PluginRegistry.PluginError.unknownTool(name)
        }
    }

    private func executeBraveSearch(argumentsJSON: String) async throws -> String {
        guard let apiKey = KeychainHelper.loadString(key: "brave-search-api-key") else {
            throw PluginError.apiError("Brave Search API key not configured. Set it in Settings → API Keys.")
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = args["query"] as? String else {
            throw PluginError.invalidArguments("brave_web_search requires a 'query' string argument")
        }

        let count = min(args["count"] as? Int ?? 5, 20)

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count)),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginError.apiError("Invalid response from Brave Search API")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw PluginError.apiError("Brave Search \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw PluginError.apiError("Failed to parse Brave Search API response")
        }

        return formatBraveSearchResults(json)
    }

    private func formatBraveSearchResults(_ json: [String: Any]) -> String {
        var output: [String] = []

        if let web = json["web"] as? [String: Any],
           let results = web["results"] as? [[String: Any]] {
            for (i, result) in results.enumerated() {
                let title = result["title"] as? String ?? ""
                let url = result["url"] as? String ?? ""
                let description = result["description"] as? String ?? ""
                output.append("[\(i + 1)] \(title)")
                output.append("    \(url)")
                if !description.isEmpty {
                    output.append("    \(description)")
                }
                output.append("")
            }
        }

        if output.isEmpty {
            return "No results found."
        }

        return output.joined(separator: "\n")
    }
}
