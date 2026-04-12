import Foundation

// MARK: - Task Plugin

@MainActor
final class TaskPlugin: Plugin {
    let id = "com.copilotchat.task"
    let name = "Task"
    let version = "1.0.0"

    private let authManager: AuthManager
    private let settingsStore: SettingsStore
    private let providerRegistry: ProviderRegistry

    init(authManager: AuthManager, settingsStore: SettingsStore, providerRegistry: ProviderRegistry) {
        self.authManager = authManager
        self.settingsStore = settingsStore
        self.providerRegistry = providerRegistry
    }

    func configure(with input: PluginInput) async throws -> PluginHooks {
        let availableTypes = SubagentRegistry.availableTypes()
        let typeDescriptions = availableTypes.map { type in
            var desc = "- **\(type.name)**: \(type.description)"
            if let t = type.thoroughness {
                desc += " Supports \(t.label) parameter (\(t.description))."
            }
            return desc
        }.joined(separator: "\n")

        let tool = MCPTool(
            name: "task",
            description: """
                Launch a new agent to handle a complex, multistep task autonomously.

                When using this tool, you must specify a subagent_type parameter to select which agent type to use.

                When to use:
                - When you are instructed to execute custom slash commands. Use this tool with the slash command invocation as the entire prompt. The slash command can take arguments. For example, Task(description="Check the file", prompt="/check-file path/to/file.py")

                When NOT to use:
                - If you want to read a specific file path, use the Read or Glob tool instead of the Task tool, to find the match more quickly.
                - If you want to search for a specific class definition like "class Foo", use the Glob tool instead of the Task tool, to find the match more quickly.
                - If you want to search for code within a specific file or set of 2-3 files, use the Read tool instead of the Task tool, to find the match more quickly.
                - Other tasks that are not related to agent descriptions below

                Available agent types:
                \(typeDescriptions)

                Usage notes:
                - Launch multiple agents concurrently whenever possible, to maximize performance; do that, use multiple Task tool calls in a single message
                - The agent's outputs should generally be trusted
                - Clearly tell the agent whether you expect it to write code or just to do research (search, file reads, web fetches, etc.), since the agent is not aware of the user's intent. Tell it how to verify its work if possible (e.g. relevant test commands).
                - The agent should use this tool proactively when it recognizes that a task matches one of the available agent types listed below.
                """,
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "subagent_type": [
                        "type": "string",
                        "description": "The name of the specialized agent to use",
                        "enum": availableTypes.map { $0.name },
                    ] as [String: Any],
                    "prompt": [
                        "type": "string",
                        "description": "The task for the agent to perform. Specify exactly what information the agent should return back to you in its final and only message to you.",
                    ] as [String: Any],
                    "description": [
                        "type": "string",
                        "description": "A short (3-5 words) description of the task",
                    ] as [String: Any],
                ] as [String: Any]),
                "required": AnyCodable(["subagent_type", "prompt", "description"]),
            ],
            serverName: name
        )

        return PluginHooks(tools: [tool]) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        }
    }

    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        guard name == "task" else {
            throw PluginRegistry.PluginError.unknownTool(name)
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagentType = args["subagent_type"] as? String,
              let prompt = args["prompt"] as? String else {
            throw PluginError.invalidArguments("task requires 'subagent_type', 'prompt', and 'description' arguments")
        }

        guard let definition = SubagentRegistry.resolve(subagentType) else {
            let available = SubagentRegistry.availableTypes().map(\.name).joined(separator: ", ")
            return ToolResult(text: "Unknown subagent type: \(subagentType). Available types: \(available)")
        }

        let result = try await runSubagent(definition: definition, prompt: prompt)
        return ToolResult(text: result)
    }

    private func runSubagent(definition: SubagentDefinition, prompt: String) async throws -> String {
        guard let provider = resolveProvider() else {
            return "Error: No LLM provider available"
        }

        let model = definition.model ?? currentModelId

        let messages: [APIMessage] = [
            APIMessage(role: "system", content: definition.systemPrompt),
            APIMessage(role: "user", content: prompt),
        ]

        let allTools = PluginRegistry.shared.allTools(for: .coding)
        let filteredTools = filterTools(allTools, for: definition)
        let apiTools: [APITool]? = filteredTools.isEmpty ? nil : filteredTools.map { tool in
            APITool(type: "function", function: .init(
                name: tool.name, description: tool.description, parameters: tool.inputSchema))
        }

        let temp = definition.temperature ?? ProviderTransform.temperature(modelId: model)
            ?? 0.7
        let maxOut = definition.maxOutputTokens ?? ProviderTransform.maxOutputTokens(
            model: nil, modelId: model)

        let options = ProviderOptions(
            maxOutputTokens: maxOut,
            temperature: temp,
            systemPrompt: definition.systemPrompt,
            toolChoice: apiTools != nil ? "auto" : nil,
            agentInitiated: true
        )

        var allContent = ""
        var currentMessages = messages
        var iterations = 0

        while iterations < definition.maxIterations {
            iterations += 1

            let stream = provider.streamCompletion(
                messages: currentMessages, model: model, tools: apiTools, options: options)

            var contentBuffer = ""
            var pendingToolCalls: [String: (id: String, name: String, arguments: String)] = [:]

            for try await event in stream {
                switch event {
                case .contentDelta(let text):
                    contentBuffer += text
                case .thinkingDelta:
                    break
                case .toolCallStart(let idx, let id, let name):
                    pendingToolCalls["\(idx)"] = (id: id, name: name, arguments: "")
                case .toolCallDelta(let idx, let arguments):
                    if pendingToolCalls["\(idx)"] != nil {
                        pendingToolCalls["\(idx)"]?.arguments += arguments
                    }
                case .toolCallStop:
                    break
                case .usage:
                    break
                case .finish(let reason):
                    if reason == .toolCalls {
                        let calls = pendingToolCalls.sorted(by: { $0.key < $1.key }).map { (_, value) in
                            ToolCall(id: value.id, function: .init(name: value.name, arguments: value.arguments))
                        }

                        currentMessages.append(APIMessage(
                            role: "assistant",
                            content: contentBuffer.isEmpty ? nil : contentBuffer,
                            toolCalls: calls.map { APIToolCall(id: $0.id, type: "function", function: .init(name: $0.function.name, arguments: $0.function.arguments)) }
                        ))

                        for call in calls {
                            let toolResult = try await executeSubagentTool(call)
                            currentMessages.append(APIMessage(
                                role: "tool",
                                content: toolResult,
                                toolCallId: call.id
                            ))
                        }
                        contentBuffer = ""
                    } else {
                        allContent += contentBuffer
                        return allContent.isEmpty ? "(subagent completed with no output)" : allContent
                    }
                case .error(let error):
                    return "Subagent error: \(error.localizedDescription)"
                }
            }

            if contentBuffer.isEmpty && pendingToolCalls.isEmpty {
                return allContent.isEmpty ? "(subagent completed with no output)" : allContent
            }
        }

        return allContent.isEmpty ? "(subagent reached max iterations)" : allContent
    }

    private func filterTools(_ tools: [MCPTool], for definition: SubagentDefinition) -> [MCPTool] {
        var filtered = tools
        if let allowed = definition.allowedTools {
            filtered = filtered.filter { allowed.contains($0.name) }
        }
        if let denied = definition.deniedTools {
            let deniedSet = denied
            filtered = filtered.filter { !deniedSet.contains($0.name) }
        }
        return filtered
    }

    private func executeSubagentTool(_ call: ToolCall) async throws -> String {
        let name = call.function.name
        let args = call.function.arguments

        if name == "tool_search" {
            let (query, maxResults) = CopilotService.parseToolSearchArgsPublic(args)
            let pluginTools = PluginRegistry.shared.allTools(for: .coding)
            let (resultText, _) = PluginRegistry.shared.searchTools(
                query: query, maxResults: maxResults, in: pluginTools
            )
            return resultText
        }

        if name == "switch_mode" {
            return "Already in coding mode for subagent execution."
        }

        for (pluginId, hooks) in PluginRegistry.shared.hooksMapSnapshot {
            if hooks.tools.contains(where: { $0.name == name }) {
                let result = try await PluginRegistry.shared.executeTool(
                    pluginId: pluginId, toolName: name, argumentsJSON: args
                )
                return result.text
            }
        }

        return "Unknown tool: \(name)"
    }

    private func resolveProvider() -> (any LLMProvider)? {
        let activeId = providerRegistry.activeProviderId
        if let provider = providerRegistry.activeProvider() {
            return provider
        }
        if activeId == "github-copilot", authManager.isAuthenticated {
            return CopilotProvider(tokenProvider: { [weak authManager] in
                await MainActor.run { authManager?.token }
            })
        }
        return nil
    }

    private var currentModelId: String {
        if !providerRegistry.activeModelId.isEmpty {
            return providerRegistry.activeModelId
        }
        return settingsStore.selectedModel
    }
}
