import Foundation

/// Built-in tools that are always available to the agent, independent of MCP servers.
enum BuiltInTools {

    static let serverName = "Built-in"

    // MARK: - Tool Definitions

    /// All built-in tools exposed to the LLM.
    static let tools: [MCPTool] = [
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
    ]

    /// Names of all built-in tools for quick lookup.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Check if a tool name belongs to a built-in tool.
    static func isBuiltIn(_ name: String) -> Bool {
        toolNames.contains(name)
    }

    // MARK: - Execution

    /// Execute a built-in tool by name. Returns the tool result as a string.
    static func execute(name: String, argumentsJSON: String) async throws -> String {
        switch name {
        case "web_fetch":
            return try await executeWebFetch(argumentsJSON: argumentsJSON)
        default:
            throw BuiltInToolError.unknownTool(name)
        }
    }

    private static func executeWebFetch(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = args["url"] as? String else {
            throw BuiltInToolError.invalidArguments("web_fetch requires a 'url' string argument")
        }
        return try await WebFetchService.fetch(url: url)
    }

    // MARK: - Errors

    enum BuiltInToolError: LocalizedError {
        case unknownTool(String)
        case invalidArguments(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown built-in tool: \(name)"
            case .invalidArguments(let msg): "Invalid arguments: \(msg)"
            }
        }
    }
}
