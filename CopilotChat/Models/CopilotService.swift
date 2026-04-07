import Foundation
import Observation

@Observable
@MainActor
final class CopilotService {
    private static let chatEndpoint = "https://api.githubcopilot.com/chat/completions"
    private static let modelsEndpoint = "https://api.githubcopilot.com/models"
    private static let userAgent = "CopilotChat/1.0.0"
    private static let maxToolIterations = 10

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
    var tokenUsage: TokenUsage?
    var isCompacting = false
    var summaryMessageId: UUID?

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
        messages.removeAll()
        toolCallStatuses.removeAll()
        tokenUsage = nil
        summaryMessageId = nil
    }

    /// Load messages from a saved conversation (for resuming).
    func loadMessages(_ saved: [ChatMessage], summaryMessageId: UUID? = nil) {
        stopStreaming()
        messages = saved
        self.summaryMessageId = summaryMessageId
        toolCallStatuses.removeAll()
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
            toolCallStatuses[call.id] = .pending
        }
        for call in calls {
            await executeSingleToolCall(call)
        }
    }

    private func executeSingleToolCall(_ call: ToolCall) async {
        toolCallStatuses[call.id] = .executing
        do {
            let result = try await settingsStore.callTool(
                name: call.function.name,
                argumentsJSON: call.function.arguments
            )
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

        let apiMessages = buildAPIMessages()
        let apiTools = tools.isEmpty ? nil : tools.map { tool in
            APITool(
                type: "function",
                function: .init(
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.inputSchema
                )
            )
        }

        let request = ChatCompletionRequest(
            model: settingsStore.selectedModel,
            messages: apiMessages,
            stream: true,
            maxTokens: 8192,
            temperature: 0.7,
            tools: apiTools,
            toolChoice: apiTools != nil ? "auto" : nil,
            streamOptions: .init(includeUsage: true)
        )

        let requestData = try JSONEncoder().encode(request)
        let urlRequest = Self.buildURLRequest(token: token, body: requestData)

        // Run the network I/O and SSE parsing off-MainActor so the UI thread stays free.
        let stream = try await Self.openSSEStream(urlRequest: urlRequest)

        // Consume parsed events on MainActor where we can safely mutate @Observable state.
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

    /// Build the URL request — pure function, no actor isolation needed.
    private static func buildURLRequest(token: String, body: Data) -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: chatEndpoint)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("conversation-edits", forHTTPHeaderField: "Openai-Intent")
        urlRequest.setValue("user", forHTTPHeaderField: "x-initiator")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        return urlRequest
    }

    /// Open the SSE connection and return an AsyncThrowingStream of parsed events.
    /// Runs the network I/O and JSON parsing on the URLSession's OperationQueue —
    /// NOT on MainActor — so the UI thread is never blocked by network delays.
    private nonisolated static func openSSEStream(
        urlRequest: URLRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        let (bytes, response) = try await urlSession.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw CopilotError.invalidResponse
        }


        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2000 { break }
            }
            throw CopilotError.httpError(http.statusCode, body)
        }

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var finishedReason: String?

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }

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

                    // Yield .finish only after the stream is fully drained
                    if let reason = finishedReason {
                        continuation.yield(.finish(reason: reason))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func buildAPIMessages() -> [APIMessage] {
        // If we have a summary, only include messages from the summary onward
        var messagesToProcess = messages
        if let summaryId = summaryMessageId,
           let summaryIndex = messagesToProcess.firstIndex(where: { $0.id == summaryId }) {
            messagesToProcess = Array(messagesToProcess[summaryIndex...])
        }

        var apiMessages: [APIMessage] = [
            APIMessage(role: "system", content: "You are a helpful AI assistant. Respond in the user's language.")
        ]

        // Collect all tool call IDs that have corresponding tool results
        let answeredToolCallIds = Set(messagesToProcess.compactMap { $0.role == .tool ? $0.toolCallId : nil })

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
                apiMessages.append(APIMessage(role: "tool", content: msg.content, toolCallId: msg.toolCallId))
            }
        }

        return apiMessages
    }

    // MARK: - Compaction

    func compactConversation() async throws {
        guard let token = authManager.token else { throw CopilotError.notAuthenticated }

        // Build current conversation messages, then swap system prompt for summarizer
        var apiMessages = buildAPIMessages()
        if !apiMessages.isEmpty && apiMessages[0].role == "system" {
            apiMessages[0] = APIMessage(role: "system", content: """
                You are a helpful AI assistant tasked with summarizing conversations.

                When asked to summarize, provide a detailed but concise summary of the conversation. \
                Focus on information that would be helpful for continuing the conversation, including:
                - What was done
                - What is currently being worked on
                - Which files are being modified
                - What needs to be done next

                Your summary should be comprehensive enough to provide context but concise enough to be quickly understood.
                """)
        }

        apiMessages.append(APIMessage(role: "user", content: """
            Provide a detailed but concise summary of our conversation above. \
            Focus on information that would be helpful for continuing the conversation, \
            including what we did, what we're doing, which files we're working on, \
            and what we're going to do next.
            """))

        let request = ChatCompletionRequest(
            model: settingsStore.selectedModel,
            messages: apiMessages,
            stream: false,
            maxTokens: 4096,
            temperature: 0.5,
            tools: nil,
            toolChoice: nil,
            streamOptions: nil
        )

        let requestData = try JSONEncoder().encode(request)
        let urlRequest = Self.buildURLRequest(token: token, body: requestData)

        let (data, response) = try await Self.urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CopilotError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        let result = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
        guard let summaryText = result.choices.first?.message.content, !summaryText.isEmpty else { return }

        // Create summary message and record its ID
        let summaryMessage = ChatMessage(role: .assistant, content: summaryText)
        messages.append(summaryMessage)
        summaryMessageId = summaryMessage.id

        // Update token usage from summary response
        if let usage = result.usage {
            tokenUsage = usage
        }
    }

    // MARK: - Fetch Models

    func fetchModels() async {
        guard let token = authManager.token else { return }

        var request = URLRequest(url: URL(string: Self.modelsEndpoint)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
