import Foundation
import UIKit

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
    let onExecute: (@Sendable (String, String) async throws -> BuiltInTools.ToolResult)?

    init(
        tools: [MCPTool] = [],
        onExecute: (@Sendable (String, String) async throws -> BuiltInTools.ToolResult)? = nil
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

    var allTools: [MCPTool] {
        var result: [MCPTool] = []
        for (pluginId, hooks) in hooksMap {
            if enabledPluginIds.contains(pluginId) {
                result.append(contentsOf: hooks.tools)
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
    private var toolHandlers: [String: @Sendable (String) async throws -> BuiltInTools.ToolResult] = [:]
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
                    try await hooks.onExecute?(toolName, args) ?? BuiltInTools.ToolResult(text: "Plugin not available")
                }
            }
        }
        plugins[browserPlugin.id] = browserPlugin
        enabledPluginIds.insert(browserPlugin.id)
    }

    func executeTool(pluginId: String, toolName: String, argumentsJSON: String) async throws -> BuiltInTools.ToolResult {
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
            guard let self else { return BuiltInTools.ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        }
    }

    @MainActor
    private func executeTool(name: String, argumentsJSON: String) async throws -> BuiltInTools.ToolResult {
        switch name {
        case "web_fetch":
            guard let url = parseURL(from: argumentsJSON) else {
                throw WebFetchService.WebFetchError.invalidURL(argumentsJSON)
            }
            let text = try await WebFetchService.fetch(url: url)
            return BuiltInTools.ToolResult(text: text)
        case "web_screenshot":
            guard let url = parseURL(from: argumentsJSON) else {
                throw WebFetchService.WebFetchError.invalidURL(argumentsJSON)
            }
            let (desc, imageData) = try await WebFetchService.screenshot(url: url)
            return BuiltInTools.ToolResult(text: desc, imageData: imageData)
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
