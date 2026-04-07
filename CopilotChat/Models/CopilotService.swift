import Foundation
import Observation

@Observable
@MainActor
final class CopilotService {
    private static let chatEndpoint = "https://api.githubcopilot.com/chat/completions"
    private static let responsesEndpoint = "https://api.githubcopilot.com/responses"
    private static let modelsEndpoint = "https://api.githubcopilot.com/models"
    private static let openCodeVersion = "1.0"
    private static let userAgent = "OpenCode/\(openCodeVersion)"
    private static let maxToolIterations = 10

    /// GPT models use Responses API; others (Claude, etc.) use Chat Completions.
    private static func useResponsesAPI(model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue())
    }()

    var messages: [ChatMessage] = []
    var isStreaming = false
    var streamingError: String?
    var availableModels: [ModelsResponse.ModelInfo] = []
    var toolCallStatuses: [String: ToolCallStatus] = [:]
    var toolCallServerNames: [String: String] = [:]
    var tokenUsage: TokenUsage?
    var isCompacting = false
    var summaryMessageId: UUID?

    // Permission flow
    private var permissionContinuation: CheckedContinuation<PermissionDecision, Never>?

    // MARK: - Context Window

    var contextWindow: Int {
        let model = availableModels.first { $0.id == settingsStore.selectedModel }
        return model?.maxPromptTokens ?? 0
    }

    private let authManager: AuthManager
    private let settingsStore: SettingsStore
    private var streamTask: Task<Void, Never>?

    init(authManager: AuthManager, settingsStore: SettingsStore) {
        self.authManager = authManager
        self.settingsStore = settingsStore
    }

    // MARK: - Chat

    func sendMessage(_ content: String, tools: [MCPTool] = []) {
        let userMessage = ChatMessage(role: .user, content: content)
        messages.append(userMessage)
        startCompletionLoop(tools: tools)
    }

    func retryToolCall(_ call: ToolCall, tools: [MCPTool] = []) {
        // Remove the previous failed tool result to avoid duplicate toolCallIds
        messages.removeAll { $0.role == .tool && $0.toolCallId == call.id }
        runStreamingTask {
            await self.executeSingleToolCall(call)
            let next = ChatMessage(role: .assistant, content: "")
            self.messages.append(next)
            try await self.completionLoop(startingAt: self.messages.count - 1, tools: tools)
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    func newConversation() {
        stopStreaming()
        // Resume any pending permission prompt so the continuation isn't leaked
        permissionContinuation?.resume(returning: .deny)
        permissionContinuation = nil
        messages.removeAll()
        toolCallStatuses.removeAll()
        toolCallServerNames.removeAll()
        tokenUsage = nil
        summaryMessageId = nil
        settingsStore.clearSessionPermissions()
    }

    func resolvePermission(_ decision: PermissionDecision) {
        permissionContinuation?.resume(returning: decision)
        permissionContinuation = nil
    }

    /// Load messages from a saved conversation (for resuming).
    func loadMessages(_ saved: [ChatMessage], summaryMessageId: UUID? = nil) {
        stopStreaming()
        messages = saved
        self.summaryMessageId = summaryMessageId
        toolCallStatuses.removeAll()
        toolCallServerNames.removeAll()
        // Restore tool call statuses — mark all as completed since they're from a saved session
        for msg in saved where msg.role == .assistant {
            if let calls = msg.toolCalls {
                for call in calls {
                    toolCallStatuses[call.id] = .completed
                }
            }
        }
    }

    // MARK: - Completion Loop

    private func runStreamingTask(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isStreaming else { return }
        isStreaming = true
        streamingError = nil
        streamTask = Task {
            do {
                try await work()
            } catch is CancellationError {
                // cancelled
            } catch {
                streamingError = error.localizedDescription
                if let last = messages.last, last.role == .assistant && last.content.isEmpty {
                    messages[messages.count - 1].content = "Error: \(error.localizedDescription)"
                }
            }
            isStreaming = false
        }
    }

    private func startCompletionLoop(tools: [MCPTool]) {
        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1
        runStreamingTask {
            try await self.completionLoop(startingAt: assistantIndex, tools: tools)
            // Auto-compact if context window is nearly full
            if self.shouldCompact {
                self.isCompacting = true
                defer { self.isCompacting = false }
                try await self.compactConversation()
            }
        }
    }

    private var shouldCompact: Bool {
        guard let usage = tokenUsage, contextWindow > 0 else { return false }
        return Double(usage.promptTokens) / Double(contextWindow) >= 0.95
    }

    private func completionLoop(startingAt index: Int, tools: [MCPTool]) async throws {
        var currentIndex = index

        for _ in 0..<Self.maxToolIterations {
            try await streamCompletion(updatingAt: currentIndex, tools: tools)

            // Check if the assistant requested tool calls
            guard let toolCalls = messages[currentIndex].toolCalls, !toolCalls.isEmpty else {
                break
            }

            try Task.checkCancellation()
            await executeToolCalls(toolCalls)

            // Prepare next assistant message for the follow-up response
            try Task.checkCancellation()
            let nextAssistant = ChatMessage(role: .assistant, content: "")
            messages.append(nextAssistant)
            currentIndex = messages.count - 1
        }
    }

    private func executeToolCalls(_ calls: [ToolCall]) async {
        for call in calls {
            let serverName = settingsStore.serverNameForTool(call.function.name) ?? "Unknown"
            toolCallServerNames[call.id] = serverName
        }
        for call in calls {
            await checkAndExecuteToolCall(call)
        }
    }

    private func checkAndExecuteToolCall(_ call: ToolCall) async {
        let serverName = toolCallServerNames[call.id] ?? "Unknown"
        let check = settingsStore.checkPermission(toolName: call.function.name, serverName: serverName)

        switch check {
        case .allowed:
            toolCallStatuses[call.id] = .pending
            await executeSingleToolCall(call)
            return
        case .denied:
            toolCallStatuses[call.id] = .failed("Blocked by tool permission")
            messages.append(ChatMessage(
                role: .tool, content: "Tool call blocked by permission settings.",
                toolCallId: call.id, toolName: call.function.name
            ))
            return
        case .ask:
            break
        }

        toolCallStatuses[call.id] = .awaitingPermission
        assert(permissionContinuation == nil, "Permission continuation overwrite — previous prompt was not resolved")
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionDecision, Never>) in
            permissionContinuation = continuation
        }

        if case .deny = decision {
            toolCallStatuses[call.id] = .failed("Permission denied")
            messages.append(ChatMessage(
                role: .tool, content: "Tool call denied by user.",
                toolCallId: call.id, toolName: call.function.name
            ))
            return
        }

        if case .allowForChat = decision { settingsStore.allowServerForSession(serverName) }
        if case .allowAlways = decision { settingsStore.allowServerAlways(serverName) }
        toolCallStatuses[call.id] = .pending
        await executeSingleToolCall(call)
    }

    private func executeSingleToolCall(_ call: ToolCall) async {
        toolCallStatuses[call.id] = .executing
        do {
            let result: String
            if BuiltInTools.isBuiltIn(call.function.name) {
                result = try await BuiltInTools.execute(
                    name: call.function.name,
                    argumentsJSON: call.function.arguments
                )
            } else {
                result = try await settingsStore.callTool(
                    name: call.function.name,
                    argumentsJSON: call.function.arguments
                )
            }
            toolCallStatuses[call.id] = .completed
            messages.append(ChatMessage(
                role: .tool, content: result,
                toolCallId: call.id, toolName: call.function.name
            ))
        } catch {
            let errorMsg = error.localizedDescription
            toolCallStatuses[call.id] = .failed(errorMsg)
            messages.append(ChatMessage(
                role: .tool, content: "Error: \(errorMsg)",
                toolCallId: call.id, toolName: call.function.name
            ))
        }
    }

    // MARK: - Streaming Implementation

    /// Parsed SSE event from the Copilot API.
    private enum SSEEvent: Sendable, CustomStringConvertible {
        case contentDelta(String)
        case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
        case usage(TokenUsage)
        case finish(reason: String)

        var description: String {
            switch self {
            case .contentDelta(let s): "contentDelta(\(s.prefix(50)))"
            case .toolCallDelta(let i, let id, let n, _): "toolCallDelta(idx=\(i), id=\(id ?? "nil"), name=\(n ?? "nil"))"
            case .usage(let u): "usage(prompt=\(u.promptTokens), completion=\(u.completionTokens))"
            case .finish(let r): "finish(\(r))"
            }
        }
    }

    private func streamCompletion(updatingAt index: Int, tools: [MCPTool]) async throws {
        guard let token = authManager.token else {
            throw CopilotError.notAuthenticated
        }

        let model = settingsStore.selectedModel
        let stream: AsyncThrowingStream<SSEEvent, Error>

        // Merge built-in tools with MCP tools
        let allTools = BuiltInTools.tools + tools

        if Self.useResponsesAPI(model: model) {
            // Responses API path
            let (instructions, input) = buildResponsesInput()
            let apiTools: [ResponsesAPITool]? = allTools.isEmpty ? nil : allTools.map { tool in
                ResponsesAPITool(type: "function", name: tool.name,
                                 description: tool.description, parameters: tool.inputSchema)
            }
            let request = ResponsesAPIRequest(
                model: model, instructions: instructions, input: input,
                stream: true, maxOutputTokens: 8192, temperature: 0.7,
                tools: apiTools, toolChoice: apiTools != nil ? "auto" : nil
            )
            let requestData = try JSONEncoder().encode(request)
            let urlRequest = Self.buildURLRequest(
                url: URL(string: Self.responsesEndpoint)!, token: token, body: requestData)
            stream = try await Self.openResponsesSSEStream(urlRequest: urlRequest)
        } else {
            // Chat Completions path
            let apiMessages = buildAPIMessages()
            let apiTools = allTools.isEmpty ? nil : allTools.map { tool in
                APITool(type: "function", function: .init(
                    name: tool.name, description: tool.description, parameters: tool.inputSchema))
            }
            let request = ChatCompletionRequest(
                model: model, messages: apiMessages, stream: true,
                maxTokens: 8192, temperature: 0.7, tools: apiTools,
                toolChoice: apiTools != nil ? "auto" : nil,
                streamOptions: .init(includeUsage: true)
            )
            let requestData = try JSONEncoder().encode(request)
            let urlRequest = Self.buildURLRequest(
                url: URL(string: Self.chatEndpoint)!, token: token, body: requestData)
            stream = try await Self.openSSEStream(urlRequest: urlRequest)
        }

        // Event consumption — identical for both APIs
        var pendingToolCalls: [String: (id: String, name: String, arguments: String)] = [:]

        for try await event in stream {
            try Task.checkCancellation()

            switch event {
            case .contentDelta(let text):
                messages[index].content += text

            case .toolCallDelta(let idx, let id, let name, let arguments):
                let key = "\(idx)"
                if let id {
                    pendingToolCalls[key] = (id: id, name: name ?? "", arguments: "")
                }
                if let name, pendingToolCalls[key] != nil {
                    pendingToolCalls[key]?.name = name
                }
                if let arguments, pendingToolCalls[key] != nil {
                    pendingToolCalls[key]?.arguments += arguments
                }

            case .usage(let usage):
                tokenUsage = usage

            case .finish(let reason):
                if reason == "tool_calls" {
                    let calls = pendingToolCalls.sorted(by: { $0.key < $1.key }).map { (_, value) in
                        ToolCall(id: value.id, function: .init(name: value.name, arguments: value.arguments))
                    }
                    messages[index].toolCalls = calls
                }
                return
            }
        }
    }

    /// Build the URL request with OpenCode-style headers.
    private static func buildURLRequest(url: URL, token: String, body: Data) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("conversation-panel", forHTTPHeaderField: "Openai-Intent")
        urlRequest.setValue("vscode-chat", forHTTPHeaderField: "Copilot-Integration-Id")
        urlRequest.setValue("OpenCode/\(openCodeVersion)", forHTTPHeaderField: "Editor-Version")
        urlRequest.setValue("OpenCode/\(openCodeVersion)", forHTTPHeaderField: "Editor-Plugin-Version")
        urlRequest.httpBody = body
        return urlRequest
    }

    /// Open a validated byte stream — shared by both SSE parsers.
    private nonisolated static func validatedBytes(
        for request: URLRequest
    ) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CopilotError.invalidResponse
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
            throw CopilotError.httpError(http.statusCode, body)
        }
        return bytes
    }

    /// Parse Chat Completions SSE stream into SSEEvent variants.
    private nonisolated static func openSSEStream(
        urlRequest: URLRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        let bytes = try await validatedBytes(for: urlRequest)

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let decoder = JSONDecoder()
                    var finishedReason: String?

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(StreamChunk.self, from: data) else { continue }

                        if let usage = chunk.usage {
                            continuation.yield(.usage(usage))
                        }

                        if finishedReason != nil { continue }

                        guard let choice = chunk.choices?.first else { continue }

                        if let content = choice.delta.content {
                            continuation.yield(.contentDelta(content))
                        }

                        if let toolCallDeltas = choice.delta.toolCalls {
                            for delta in toolCallDeltas {
                                continuation.yield(.toolCallDelta(
                                    index: delta.index,
                                    id: delta.id,
                                    name: delta.function?.name,
                                    arguments: delta.function?.arguments
                                ))
                            }
                        }

                        if let finishReason = choice.finishReason {
                            finishedReason = finishReason
                        }
                    }

                    if let reason = finishedReason {
                        continuation.yield(.finish(reason: reason))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Max chars for historical (non-current-turn) tool results sent to the API.
    private static let maxHistoricalToolResultChars = 200

    private func preparedMessages() -> (messages: [ChatMessage], answeredToolCallIds: Set<String>, currentTurnToolIds: Set<String>) {
        var msgs = messages
        if let summaryId = summaryMessageId,
           let summaryIndex = msgs.firstIndex(where: { $0.id == summaryId }) {
            msgs = Array(msgs[summaryIndex...])
        }
        let answered = Set(msgs.compactMap { $0.role == .tool ? $0.toolCallId : nil })

        // Find the last assistant message that issued tool calls — those are "current turn" results.
        var currentIds = Set<String>()
        for msg in msgs.reversed() {
            if let calls = msg.toolCalls, !calls.isEmpty {
                currentIds = Set(calls.map(\.id))
                break
            }
        }
        return (msgs, answered, currentIds)
    }

    /// Truncate a tool result that belongs to a previous turn.
    private static func truncateHistoricalToolResult(_ content: String) -> String {
        guard let idx = content.index(content.startIndex,
                                      offsetBy: maxHistoricalToolResultChars,
                                      limitedBy: content.endIndex) else { return content }
        return String(content[..<idx]) + "\n[…truncated]"
    }

    /// Resolve tool message content, truncating historical results.
    private static func resolvedToolContent(_ content: String, callId: String?, currentTurnToolIds: Set<String>) -> String {
        if let id = callId, currentTurnToolIds.contains(id) { return content }
        return truncateHistoricalToolResult(content)
    }

    func buildAPIMessages() -> [APIMessage] {
        let (messagesToProcess, answeredToolCallIds, currentTurnToolIds) = preparedMessages()

        var apiMessages: [APIMessage] = [
            APIMessage(role: "system", content: Self.systemInstructions)
        ]

        for msg in messagesToProcess {
            switch msg.role {
            case .system:
                continue
            case .user:
                apiMessages.append(APIMessage(role: "user", content: msg.content))
            case .assistant:
                // Summary message is sent as user role to provide context
                if msg.id == summaryMessageId {
                    apiMessages.append(APIMessage(role: "user", content: msg.content))
                    continue
                }
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    // Only include tool calls that have corresponding results
                    let answeredCalls = toolCalls.filter { answeredToolCallIds.contains($0.id) }
                    if !answeredCalls.isEmpty {
                        let apiToolCalls = answeredCalls.map {
                            APIToolCall(id: $0.id, type: "function", function: .init(name: $0.function.name, arguments: $0.function.arguments))
                        }
                        apiMessages.append(APIMessage(role: "assistant", content: msg.content.isEmpty ? nil : msg.content, toolCalls: apiToolCalls))
                    } else if !msg.content.isEmpty {
                        apiMessages.append(APIMessage(role: "assistant", content: msg.content))
                    }
                } else if !msg.content.isEmpty {
                    apiMessages.append(APIMessage(role: "assistant", content: msg.content))
                }
            case .tool:
                let content = Self.resolvedToolContent(msg.content, callId: msg.toolCallId, currentTurnToolIds: currentTurnToolIds)
                apiMessages.append(APIMessage(role: "tool", content: content, toolCallId: msg.toolCallId))
            }
        }

        return apiMessages
    }

    // MARK: - Responses API Input Builder

    func buildResponsesInput() -> (instructions: String, input: [ResponsesInputItem]) {
        let (messagesToProcess, answeredToolCallIds, currentTurnToolIds) = preparedMessages()

        let instructions = Self.systemInstructions
        var input: [ResponsesInputItem] = []

        for msg in messagesToProcess {
            switch msg.role {
            case .system:
                continue
            case .user:
                input.append(.userMessage(content: msg.content))
            case .assistant:
                if msg.id == summaryMessageId {
                    input.append(.userMessage(content: msg.content))
                    continue
                }
                if !msg.content.isEmpty {
                    input.append(.assistantMessage(content: msg.content))
                }
                if let toolCalls = msg.toolCalls {
                    for call in toolCalls where answeredToolCallIds.contains(call.id) {
                        input.append(.functionCall(
                            callId: call.id, name: call.function.name,
                            arguments: call.function.arguments
                        ))
                    }
                }
            case .tool:
                if let callId = msg.toolCallId {
                    let output = Self.resolvedToolContent(msg.content, callId: callId, currentTurnToolIds: currentTurnToolIds)
                    input.append(.functionCallOutput(callId: callId, output: output))
                }
            }
        }
        return (instructions, input)
    }

    // MARK: - Responses API SSE Stream

    /// Parse Responses API SSE stream (typed events) into the same SSEEvent variants.
    private nonisolated static func openResponsesSSEStream(
        urlRequest: URLRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        let bytes = try await validatedBytes(for: urlRequest)

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let decoder = JSONDecoder()
                    var currentEventType: String?
                    var hasToolCalls = false

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        if line.hasPrefix("event: ") {
                            currentEventType = String(line.dropFirst(7))
                            continue
                        }

                        guard line.hasPrefix("data: "),
                              let eventType = currentEventType else { continue }
                        let payload = String(line.dropFirst(6))
                        currentEventType = nil

                        guard let data = payload.data(using: .utf8) else { continue }

                        switch eventType {
                        case "response.output_text.delta":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data),
                               let delta = evt.delta {
                                continuation.yield(.contentDelta(delta))
                            }

                        case "response.output_item.added":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data),
                               let item = evt.item, item.type == "function_call" {
                                let idx = evt.outputIndex ?? 0
                                hasToolCalls = true
                                continuation.yield(.toolCallDelta(
                                    index: idx, id: item.callId, name: item.name, arguments: nil
                                ))
                            }

                        case "response.function_call_arguments.delta":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data) {
                                let idx = evt.outputIndex ?? 0
                                continuation.yield(.toolCallDelta(
                                    index: idx, id: nil, name: nil, arguments: evt.delta
                                ))
                            }

                        case "response.completed":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data),
                               let usage = evt.response?.usage {
                                continuation.yield(.usage(usage.asTokenUsage))
                            }
                            continuation.yield(.finish(reason: hasToolCalls ? "tool_calls" : "stop"))

                        case "response.failed":
                            continuation.yield(.finish(reason: "error"))

                        case "response.incomplete":
                            continuation.yield(.finish(reason: "length"))

                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Compaction

    private static let systemInstructions = "You are a helpful AI assistant. Respond in the user's language."

    private static let summarizerInstructions = """
        You are a helpful AI assistant tasked with summarizing conversations.

        When asked to summarize, provide a detailed but concise summary of the conversation. \
        Focus on information that would be helpful for continuing the conversation, including:
        - What was done
        - What is currently being worked on
        - Which files are being modified
        - What needs to be done next

        Your summary should be comprehensive enough to provide context but concise enough to be quickly understood.
        """

    private static let summarizerPrompt = """
        Provide a detailed but concise summary of our conversation above. \
        Focus on information that would be helpful for continuing the conversation, \
        including what we did, what we're doing, which files we're working on, \
        and what we're going to do next.
        """

    func compactConversation() async throws {
        guard let token = authManager.token else { throw CopilotError.notAuthenticated }

        let model = settingsStore.selectedModel
        let isResponses = Self.useResponsesAPI(model: model)
        let requestData: Data
        let url: URL

        if isResponses {
            let (_, input) = buildResponsesInput()
            var fullInput = input
            fullInput.append(.userMessage(content: Self.summarizerPrompt))
            let request = ResponsesAPIRequest(
                model: model, instructions: Self.summarizerInstructions,
                input: fullInput, stream: false,
                maxOutputTokens: 4096, temperature: 0.5,
                tools: nil, toolChoice: nil
            )
            requestData = try JSONEncoder().encode(request)
            url = URL(string: Self.responsesEndpoint)!
        } else {
            var apiMessages = buildAPIMessages()
            if !apiMessages.isEmpty && apiMessages[0].role == "system" {
                apiMessages[0] = APIMessage(role: "system", content: Self.summarizerInstructions)
            }
            apiMessages.append(APIMessage(role: "user", content: Self.summarizerPrompt))
            let request = ChatCompletionRequest(
                model: model, messages: apiMessages, stream: false,
                maxTokens: 4096, temperature: 0.5,
                tools: nil, toolChoice: nil, streamOptions: nil
            )
            requestData = try JSONEncoder().encode(request)
            url = URL(string: Self.chatEndpoint)!
        }

        let urlRequest = Self.buildURLRequest(url: url, token: token, body: requestData)

        let (data, response) = try await Self.urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CopilotError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        let summaryText: String?
        let usage: TokenUsage?

        if isResponses {
            let result = try JSONDecoder().decode(NonStreamingResponsesResponse.self, from: data)
            summaryText = result.output.first?.content?.first(where: { $0.type == "output_text" })?.text
            usage = result.usage?.asTokenUsage
        } else {
            let result = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
            summaryText = result.choices.first?.message.content
            usage = result.usage
        }

        guard let text = summaryText, !text.isEmpty else { return }
        let summaryMessage = ChatMessage(role: .assistant, content: text)
        messages.append(summaryMessage)
        summaryMessageId = summaryMessage.id
        if let usage { tokenUsage = usage }
    }

    // MARK: - Fetch Models

    func fetchModels() async {
        guard let token = authManager.token else { return }

        var request = URLRequest(url: URL(string: Self.modelsEndpoint)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode-chat", forHTTPHeaderField: "Copilot-Integration-Id")
        request.setValue("OpenCode/\(Self.openCodeVersion)", forHTTPHeaderField: "Editor-Version")
        request.setValue("OpenCode/\(Self.openCodeVersion)", forHTTPHeaderField: "Editor-Plugin-Version")

        do {
            let (data, response) = try await Self.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            availableModels = modelsResponse.data.sorted { $0.id < $1.id }
        } catch {
            // Non-critical
        }
    }

    // MARK: - Errors

    enum CopilotError: LocalizedError {
        case notAuthenticated
        case invalidResponse
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: "Not authenticated. Please sign in to GitHub."
            case .invalidResponse: "Invalid response from server."
            case .httpError(let code, let body): "HTTP \(code): \(body)"
            }
        }
    }
}
