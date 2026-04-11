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

struct PluginHooks: Sendable {
    let tools: [MCPTool]
    let onExecute: (@Sendable (String, String) async throws -> ToolResult)?

    init(
        tools: [MCPTool] = [],
        onExecute: (@Sendable (String, String) async throws -> ToolResult)? = nil
    ) {
        self.tools = tools
        self.onExecute = onExecute
    }
}

// ===== Plugin Registry =====

@Observable
@MainActor
final class PluginRegistry {
    static let shared = PluginRegistry()

    func allTools(for mode: AppMode) -> [MCPTool] {
        var result = baseTools
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
    private var hooksMap: [String: PluginHooks] = [:]
    private var enabledPluginIds: Set<String> = []

    private init() {}

    @discardableResult
    func register<P: Plugin>(_ plugin: P) -> String {
        plugins[plugin.id] = plugin
        enabledPluginIds.insert(plugin.id)
        return plugin.id
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

    func loadPlugins() async {
        await registerBuiltInPlugins()
    }

    private func registerBuiltInPlugins() async {
        let input = PluginInput(deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown")
        let browserPlugin = BrowserPlugin()
        if let hooks = try? await browserPlugin.configure(with: input) {
            hooksMap[browserPlugin.id] = hooks
            for tool in hooks.tools {
                let pluginId = browserPlugin.id
                let toolName = tool.name
                toolHandlers["\(pluginId).\(toolName)"] = { args in
                    try await hooks.onExecute?(toolName, args) ?? ToolResult(text: "Plugin not available")
                }
            }
        }
        plugins[browserPlugin.id] = browserPlugin
        enabledPluginIds.insert(browserPlugin.id)

        let braveSearchPlugin = BraveSearchPlugin()
        if let hooks = try? await braveSearchPlugin.configure(with: input) {
            hooksMap[braveSearchPlugin.id] = hooks
            for tool in hooks.tools {
                let pluginId = braveSearchPlugin.id
                let toolName = tool.name
                toolHandlers["\(pluginId).\(toolName)"] = { args in
                    try await hooks.onExecute?(toolName, args) ?? ToolResult(text: "Plugin not available")
                }
            }
        }
        plugins[braveSearchPlugin.id] = braveSearchPlugin
        enabledPluginIds.insert(braveSearchPlugin.id)

        let fileSystemPlugin = FileSystemPlugin()
        if let hooks = try? await fileSystemPlugin.configure(with: input) {
            hooksMap[fileSystemPlugin.id] = hooks
            for tool in hooks.tools {
                let pluginId = fileSystemPlugin.id
                let toolName = tool.name
                toolHandlers["\(pluginId).\(toolName)"] = { args in
                    try await hooks.onExecute?(toolName, args) ?? ToolResult(text: "Plugin not available")
                }
            }
        }
        plugins[fileSystemPlugin.id] = fileSystemPlugin
        enabledPluginIds.insert(fileSystemPlugin.id)
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

    func plugin(for id: String) -> (any Plugin)? {
        plugins[id]
    }

    func hooks(for id: String) -> PluginHooks? {
        hooksMap[id]
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
