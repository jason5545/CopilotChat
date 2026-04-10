import Foundation

/// Built-in tools that are always available to the agent, independent of MCP servers.
enum BuiltInTools {

    static let serverName = "Built-in"

    /// Result from a built-in tool execution. May include image data for vision models.
    struct ToolResult {
        let text: String
        let imageData: Data?

        init(text: String, imageData: Data? = nil) {
            self.text = text
            self.imageData = imageData
        }
    }

    // MARK: - Tool Definitions

    static let braveSearchKeychainKey = "brave-search-api-key"
    private nonisolated(unsafe) static var _cachedTools: [MCPTool]?

    /// Base tools that are always available.
    private static let baseTools: [MCPTool] = []

    private static let braveSearchTool = MCPTool(
        name: "brave_web_search",
        description: "Search the web using Brave Search. Returns web search results including titles, URLs, and descriptions. Useful for finding current information, researching topics, or answering questions that require up-to-date web data.",
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
        serverName: serverName
    )

    /// All built-in tools exposed to the LLM. Conditionally includes tools that require API keys.
    /// Cached to avoid repeated Keychain reads. Call `invalidateToolsCache()` when API keys change.
    static var tools: [MCPTool] {
        if let cached = _cachedTools { return cached }
        var result = baseTools
        if KeychainHelper.loadString(key: braveSearchKeychainKey) != nil {
            result.append(braveSearchTool)
        }
        _cachedTools = result
        return result
    }

    static func invalidateToolsCache() {
        _cachedTools = nil
    }

    // MARK: - Tool Search (deferred loading)

    static let toolSearchName = "tool_search"

    static let toolSearchTool = MCPTool(
        name: toolSearchName,
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
        serverName: serverName
    )

    /// Search available MCP tools by name or keyword. Returns formatted results and the names of matched tools.
    static func searchTools(query: String, maxResults: Int = 5, in availableTools: [MCPTool]) -> (text: String, matchedNames: [String]) {
        let q = query.lowercased()

        // 1. Exact name match
        if let exact = availableTools.first(where: { $0.name.lowercased() == q }) {
            let text = formatToolResult(exact)
            return (text, [exact.name])
        }

        // 2. Name-contains match, then description-contains
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

    private static func formatToolResult(_ tool: MCPTool) -> String {
        var result = "**\(tool.name)** (server: \(tool.serverName))\n\(tool.description)"
        if let schema = tool.inputSchema {
            if let data = try? JSONSerialization.data(withJSONObject: schema.mapValues(\.value), options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                result += "\n\nParameters:\n```json\n\(json)\n```"
            }
        }
        return result
    }

    /// All possible built-in tool names, including those that may not be currently active.
    private static let allToolNames: Set<String> = {
        var names = Set(baseTools.map(\.name))
        names.insert(braveSearchTool.name)
        names.insert(toolSearchName)
        return names
    }()

    /// Check if a tool name belongs to a built-in tool.
    static func isBuiltIn(_ name: String) -> Bool {
        allToolNames.contains(name)
    }

    // MARK: - Execution

    /// Execute a built-in tool by name. Returns a ToolResult with text and optional image data.
    static func execute(name: String, argumentsJSON: String) async throws -> ToolResult {
        switch name {
        case "web_fetch":
            guard let url = parseURLArgument(from: argumentsJSON) else {
                throw BuiltInToolError.invalidArguments("web_fetch requires a 'url' string argument")
            }
            let text = try await WebFetchService.fetch(url: url)
            return ToolResult(text: text)
        case "web_screenshot":
            guard let url = parseURLArgument(from: argumentsJSON) else {
                throw BuiltInToolError.invalidArguments("web_screenshot requires a 'url' string argument")
            }
            let (desc, imageData) = try await WebFetchService.screenshot(url: url)
            return ToolResult(text: desc, imageData: imageData)
        case "brave_web_search":
            let text = try await executeBraveSearch(argumentsJSON: argumentsJSON)
            return ToolResult(text: text)
        case toolSearchName:
            // tool_search execution is handled by CopilotService (needs MCP tool list)
            throw BuiltInToolError.invalidArguments("tool_search must be executed via CopilotService")
        default:
            throw BuiltInToolError.unknownTool(name)
        }
    }

    // MARK: - Brave Search

    private static func executeBraveSearch(argumentsJSON: String) async throws -> String {
        guard let apiKey = KeychainHelper.loadString(key: braveSearchKeychainKey) else {
            throw BuiltInToolError.apiError("Brave Search API key not configured. Set it in Settings → API Keys.")
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = args["query"] as? String else {
            throw BuiltInToolError.invalidArguments("brave_web_search requires a 'query' string argument")
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
            throw BuiltInToolError.apiError("Invalid response from Brave Search API")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw BuiltInToolError.apiError("Brave Search \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw BuiltInToolError.apiError("Failed to parse Brave Search API response")
        }

        return formatBraveSearchResults(json)
    }

    private static func formatBraveSearchResults(_ json: [String: Any]) -> String {
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

    // MARK: - Helpers

    private static func parseURLArgument(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = args["url"] as? String else {
            return nil
        }
        return url
    }

    // MARK: - Errors

    enum BuiltInToolError: LocalizedError {
        case unknownTool(String)
        case invalidArguments(String)
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown built-in tool: \(name)"
            case .invalidArguments(let msg): "Invalid arguments: \(msg)"
            case .apiError(let msg): "API error: \(msg)"
            }
        }
    }
}
