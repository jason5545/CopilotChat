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

    /// Names of all built-in tools for quick lookup.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Check if a tool name belongs to a built-in tool.
    static func isBuiltIn(_ name: String) -> Bool {
        toolNames.contains(name)
    }

    // MARK: - Execution

    /// Execute a built-in tool by name. Returns a ToolResult with text and optional image data.
    static func execute(name: String, argumentsJSON: String) async throws -> ToolResult {
        guard let url = parseURLArgument(from: argumentsJSON) else {
            throw BuiltInToolError.invalidArguments("\(name) requires a 'url' string argument")
        }
        switch name {
        case "web_fetch":
            let text = try await WebFetchService.fetch(url: url)
            return ToolResult(text: text)
        case "web_screenshot":
            let (desc, imageData) = try await WebFetchService.screenshot(url: url)
            return ToolResult(text: desc, imageData: imageData)
        default:
            throw BuiltInToolError.unknownTool(name)
        }
    }

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

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name): "Unknown built-in tool: \(name)"
            case .invalidArguments(let msg): "Invalid arguments: \(msg)"
            }
        }
    }
}
