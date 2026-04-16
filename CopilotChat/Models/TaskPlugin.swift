import Foundation

// MARK: - Subagent Session

struct SubagentSession: Sendable {
    let id: String
    let definition: SubagentDefinition
    var messages: [APIMessage]
    var lastActiveAt: Date

    init(definition: SubagentDefinition) {
        self.id = UUID().uuidString
        self.definition = definition
        self.messages = []
        self.lastActiveAt = Date()
    }
}

// MARK: - Task Plugin

@MainActor
final class TaskPlugin: Plugin {
    let id = "com.copilotchat.task"
    let name = "Task"
    let version = "1.0.0"

    private let authManager: AuthManager
    private let settingsStore: SettingsStore
    private let providerRegistry: ProviderRegistry
    private var sessions: [String: SubagentSession] = [:]

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
                - When you are instructed to execute custom slash commands. Use this tool with the slash command invocation as the entire prompt. For example, Task(description="Check the file", prompt="/check-file path/to/file.py")
                - When you need to explore a codebase and gather information that would take a long time in a single response

                When NOT to use:
                - If you want to read a specific file path, use the Read or Glob tool instead, to find the match more quickly
                - If you want to search for a specific class definition like "class Foo", use the Glob tool instead
                - If you want to search for code within a specific file or set of 2-3 files, use the Read tool instead

                Available agent types:
                \(typeDescriptions)

                Usage notes:
                - If you call this tool multiple times in the same response, do it concurrently
                - The agent's outputs should generally be trusted
                - If the task needs to be continued later, save the returned task_id and pass it to resume
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
                    "task_id": [
                        "type": "string",
                        "description": "Pass a prior task_id to continue the same subagent session instead of creating a fresh one. Use this when the task needs to be resumed.",
                    ] as [String: Any],
                ] as [String: Any]),
                "required": AnyCodable(["subagent_type", "prompt", "description"]),
            ] as [String: AnyCodable],
            serverName: name
        )

        return PluginHooks(tools: [tool]) { [weak self] toolName, argumentsJSON in
            guard let self else { return ToolResult(text: "Plugin unavailable") }
            return try await self.executeTool(name: toolName, argumentsJSON: argumentsJSON)
        }
    }

    func cancelTask(sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }

    private func executeTool(name: String, argumentsJSON: String) async throws -> ToolResult {
        guard name == "task" else {
            throw PluginRegistry.PluginError.unknownTool(name)
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subagentType = args["subagent_type"] as? String,
              let prompt = args["prompt"] as? String,
              let description = args["description"] as? String else {
            throw PluginError.invalidArguments("task requires 'subagent_type', 'prompt', and 'description' arguments")
        }

        let taskId = args["task_id"] as? String

        guard let definition = SubagentRegistry.resolve(subagentType) else {
            let available = SubagentRegistry.availableTypes().map(\.name).joined(separator: ", ")
            return ToolResult(text: "Unknown subagent type: \(subagentType). Available types: \(available)")
        }

        if let taskId, let existing = sessions[taskId] {
            let result = try await resumeSubagent(sessionId: taskId, prompt: prompt)
            return ToolResult(text: """
                task_id: \(taskId)

                <task_result>
                \(result)
                </task_result>
                """)
        } else {
            let result = try await runSubagent(definition: definition, prompt: prompt, description: description)
            return ToolResult(text: result)
        }
    }

    private func resumeSubagent(sessionId: String, prompt: String) async throws -> String {
        guard var session = sessions[sessionId] else {
            return "Session not found: \(sessionId)"
        }

        session.messages.append(APIMessage(role: "user", content: prompt))
        session.lastActiveAt = Date()

        let result = try await runSubagentSession(&session)
        sessions[sessionId] = session
        return result
    }

    private func runSubagent(definition: SubagentDefinition, prompt: String, description: String) async throws -> String {
        guard let provider = resolveProvider() else {
            return "Error: No LLM provider available"
        }

        var session = SubagentSession(definition: definition)
        sessions[session.id] = session

        let result = try await runSubagentSession(&session)
        sessions[session.id] = session
        return """
            task_id: \(session.id) (for resuming to continue this task if needed)

            <task_result>
            \(result)
            </task_result>
            """
    }

    private func runSubagentSession(_ session: inout SubagentSession) async throws -> String {
        guard let provider = resolveProvider() else {
            return "Error: No LLM provider available"
        }

        let definition = session.definition
        let model = resolveModel(for: definition)

        let systemPrompt = buildSystemPrompt(for: definition)
        if session.messages.first?.role != "system" {
            session.messages.insert(APIMessage(role: "system", content: systemPrompt), at: 0)
        }

        let allPluginTools = PluginRegistry.shared.allTools(for: .coding)
        let filteredTools = filterTools(allPluginTools, rules: definition.permissionRules)
        let apiTools: [APITool]? = filteredTools.isEmpty ? nil : filteredTools.map { tool in
            APITool(type: "function", function: .init(
                name: tool.name, description: tool.description, parameters: tool.inputSchema))
        }

        let modelInfo = providerRegistry.modelsDevProviders[providerRegistry.activeProviderId]?.models[model]
        let temp = ProviderTransform.requestTemperature(
            modelId: model,
            model: modelInfo,
            preferred: definition.temperature ?? 0.7
        )
        let maxOut = definition.maxOutputTokens ?? ProviderTransform.maxOutputTokens(model: nil, modelId: model)

        let options = ProviderOptions(
            maxOutputTokens: maxOut,
            temperature: temp,
            systemPrompt: systemPrompt,
            toolChoice: apiTools != nil ? "auto" : nil,
            agentInitiated: true
        )

        var allContent = ""
        var iterations = 0
        let maxIterations = definition.maxIterations

        while iterations < maxIterations {
            iterations += 1

            do {
                let (content, newMessages) = try await streamSubagent(provider: provider, model: model, messages: session.messages, tools: apiTools, options: options, definition: definition)
                session.messages.append(contentsOf: newMessages)
                if let lastAssistant = newMessages.last, lastAssistant.role == "assistant", let toolCalls = lastAssistant.toolCalls, !toolCalls.isEmpty {
                    session.messages.append(APIMessage(role: "user", content: "Continue if there is more work to do, otherwise return your final answer."))
                    allContent = content
                    continue
                }
                allContent = content
                break
            } catch is CancellationError {
                return "Task cancelled."
            } catch {
                return "Subagent error: \(error.localizedDescription)"
            }
        }

        if iterations >= maxIterations {
            return allContent.isEmpty ? "(subagent reached max iterations)" : allContent
        }

        return allContent.isEmpty ? "(subagent completed with no output)" : allContent
    }

    private func streamSubagent(
        provider: any LLMProvider,
        model: String,
        messages: [APIMessage],
        tools: [APITool]?,
        options: ProviderOptions,
        definition: SubagentDefinition
    ) async throws -> (content: String, newMessages: [APIMessage]) {
        let stream = provider.streamCompletion(messages: messages, model: model, tools: tools, options: options)

        var contentBuffer = ""
        var pendingToolCalls: [String: (id: String, name: String, arguments: String)] = [:]
        var finishReason: ChatMessage.FinishReason = .stop

        for try await event in stream {
            try Task.checkCancellation()
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
                finishReason = reason
            case .error:
                break
            }
        }

        var newMessages: [APIMessage] = []

        if finishReason == .toolCalls && !pendingToolCalls.isEmpty {
            let calls = pendingToolCalls.sorted(by: { $0.key < $1.key }).map { (_, value) in
                ToolCall(id: value.id, function: .init(name: value.name, arguments: value.arguments))
            }

            newMessages.append(APIMessage(
                role: "assistant",
                content: contentBuffer.isEmpty ? nil : contentBuffer,
                toolCalls: calls.map { APIToolCall(id: $0.id, type: "function", function: .init(name: $0.function.name, arguments: $0.function.arguments)) }
            ))

            for call in calls {
                let action = checkPermission(call.function.name, rules: definition.permissionRules)
                let result: String
                switch action {
                case .allow:
                    result = try await executeSubagentTool(call, rules: definition.permissionRules)
                case .deny:
                    result = "Tool denied by subagent permission rules: \(call.function.name)"
                case .ask:
                    result = "Tool requires user permission: \(call.function.name)"
                }
                newMessages.append(APIMessage(role: "tool", content: result, toolCallId: call.id))
            }
            contentBuffer = ""
        }

        if finishReason != .toolCalls || pendingToolCalls.isEmpty {
            newMessages.append(APIMessage(role: "assistant", content: contentBuffer))
            return (contentBuffer, newMessages)
        }

        return ("", newMessages)
    }

    private func buildSystemPrompt(for definition: SubagentDefinition) -> String {
        let allowedToolNames = allowedToolNames(for: definition)
        let allowedToolsLine = allowedToolNames.joined(separator: ", ")
        let prompt = definition.systemPrompt
        if allowedToolsLine.isEmpty {
            return prompt
        }
        return prompt + "\n\nAvailable tools: \(allowedToolsLine)."
    }

    private func allowedToolNames(for definition: SubagentDefinition) -> [String] {
        definition.permissionRules
            .filter { $0.action == .allow && $0.toolName != "*" }
            .map(\.toolName)
    }

    private func filterTools(_ tools: [MCPTool], rules: [ToolPermissionRule]) -> [MCPTool] {
        tools.filter { tool in
            let action = checkPermission(tool.name, rules: rules)
            return action == .allow
        }
    }

    private func checkPermission(_ toolName: String, rules: [ToolPermissionRule]) -> ToolPermissionAction {
        for rule in rules {
            if rule.toolName == toolName || rule.toolName == "*" {
                return rule.action
            }
        }
        return .ask
    }

    private func executeSubagentTool(_ call: ToolCall, rules: [ToolPermissionRule]) async throws -> String {
        let name = call.function.name
        let args = call.function.arguments

        let action = checkPermission(name, rules: rules)
        if action == .deny {
            return "Tool denied by subagent permission rules: \(name)"
        }

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

    private func resolveModel(for definition: SubagentDefinition) -> String {
        if let model = definition.model, !model.isEmpty {
            return model
        }
        if !providerRegistry.activeModelId.isEmpty {
            return providerRegistry.activeModelId
        }
        return settingsStore.selectedModel
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
}
