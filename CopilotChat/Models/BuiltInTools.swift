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
    private static let baseTools: [MCPTool] = [
        MCPTool(
            name: "web_fetch",
            description: "Fetch the text content of a web page. Provide a URL and receive the page's text content with HTML tags stripped. Useful for reading articles, documentation, or any public web page.",
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
            serverName: serverName
        ),
        MCPTool(
            name: "web_screenshot",
            description: "Take a visual screenshot of a web page. Returns an image of the rendered page as seen in a mobile browser. Useful for seeing page layout, visual design, charts, or any content that requires visual inspection.",
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
            serverName: serverName
        ),
    ]

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

    /// All possible built-in tool names, including those that may not be currently active.
    private static let allToolNames: Set<String> = {
        var names = Set(baseTools.map(\.name))
        names.insert(braveSearchTool.name)
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
