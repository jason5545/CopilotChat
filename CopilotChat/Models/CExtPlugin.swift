import Foundation

final class CExtPlugin: Plugin, @unchecked Sendable {
    let id: String
    let name: String
    let version: String
    let bundlePath: String

    private var loader: JavaScriptCorePluginLoader?
    private var loadedTools: [CExtToolDefinition] = []

    init(id: String, name: String, version: String, bundlePath: String) {
        self.id = id
        self.name = name
        self.version = version
        self.bundlePath = bundlePath
    }

    @MainActor
    func configure(with input: PluginInput) async throws -> PluginHooks {
        let loader = JavaScriptCorePluginLoader()
        let result = try await loader.load(from: bundlePath)

        self.loader = loader
        self.loadedTools = result.tools

        let mcpTools = result.tools.map { tool in
            MCPTool(
                name: tool.name,
                description: tool.description,
                inputSchema: schemaForTool(tool),
                serverName: result.name
            )
        }

        return PluginHooks(tools: mcpTools) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            guard let handler = await self.loader?.handler(for: toolName) else {
                return ToolResult(text: "Tool \(toolName) not found")
            }
            return try await handler(argumentsJSON)
        }
    }

    private func schemaForTool(_ tool: CExtToolDefinition) -> [String: AnyCodable]? {
        var properties: [String: Any] = [:]
        var required: [String] = []

        if let args = tool.args {
            for arg in args {
                properties[arg.name] = [
                    "type": arg.type,
                    "description": arg.description ?? ""
                ]
                if arg.required {
                    required.append(arg.name)
                }
            }
        }

        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(properties),
            "required": AnyCodable(required)
        ]
    }
}


