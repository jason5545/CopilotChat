import Foundation

// MARK: - GitHub Copilot Provider

/// Provider for GitHub Copilot API. Uses GitHub OAuth token for auth,
/// then routes to Chat Completions (Claude) or Responses API (GPT/O-series).
struct CopilotProvider: LLMProvider, @unchecked Sendable {
    let id = "github-copilot"
    let displayName = "GitHub Copilot"

    private static let chatEndpoint = "https://api.githubcopilot.com/chat/completions"
    private static let responsesEndpoint = "https://api.githubcopilot.com/responses"
    private static let modelsEndpoint = "https://api.githubcopilot.com/models"
    private static let version = "1.0.0"
    private static let userAgent = "opencode/\(version)"

    private let tokenProvider: @Sendable () async -> String?

    init(tokenProvider: @escaping @Sendable () async -> String?) {
        self.tokenProvider = tokenProvider
    }

    /// Whether the current message payload contains image content.
    private static func hasVisionContent(messages: [APIMessage]) -> Bool {
        messages.contains { msg in
            msg.contentParts?.contains { part in
                if case .imageURL = part { return true }
                return false
            } ?? false
        }
    }

    /// Whether the last message is not from user (agent-initiated).
    private static func isAgentInitiated(messages: [APIMessage]) -> Bool {
        guard let last = messages.last else { return false }
        return last.role != "user"
    }

    // MARK: - Routing

    private static func useResponsesAPI(model: String) -> Bool {
        SSEParser.useResponsesAPI(model: model)
    }

    // MARK: - LLMProvider

    func streamCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    guard let token = await tokenProvider() else {
                        throw ProviderError.noAPIKey
                    }

                    if Self.useResponsesAPI(model: model) {
                        let stream = try await streamResponsesAPI(
                            messages: messages, model: model, tools: tools,
                            options: options, token: token)
                        for try await event in stream {
                            continuation.yield(event)
                        }
                    } else {
                        let stream = try await streamChatCompletions(
                            messages: messages, model: model, tools: tools,
                            options: options, token: token)
                        for try await event in stream {
                            continuation.yield(event)
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

    func sendCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) async throws -> ProviderResponse {
        guard let token = await tokenProvider() else {
            throw ProviderError.noAPIKey
        }

        // Non-streaming: use Chat Completions with stream=false
        let apiTools = tools
        let request = ChatCompletionRequest(
            model: model, messages: messages, stream: false,
            maxTokens: options.maxOutputTokens, temperature: options.temperature ?? 0.7,
            tools: apiTools, toolChoice: nil,
            streamOptions: nil, reasoningEffort: options.reasoningEffort
        )
        let requestData = try JSONEncoder().encode(request)
        let urlRequest = buildURLRequest(
            url: URL(string: Self.chatEndpoint)!, token: token, body: requestData,
            model: model, messages: messages)

        let (data, response) = try await SSEParser.urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.invalidResponse(statusCode: code, body: body)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        let content = decoded.choices.first?.message.content
        let toolCalls = decoded.choices.first?.message.toolCalls?.map { tc in
            ToolCall(id: tc.id, function: .init(name: tc.function.name, arguments: tc.function.arguments))
        } ?? []
        let finishReason = decoded.choices.first?.finishReason
            .flatMap { ChatMessage.FinishReason(rawValue: $0) }

        return ProviderResponse(
            content: content,
            toolCalls: toolCalls,
            usage: decoded.usage,
            finishReason: finishReason
        )
    }

    // MARK: - Chat Completions Stream

    private func streamChatCompletions(
        messages: [APIMessage], model: String, tools: [APITool]?,
        options: ProviderOptions, token: String
    ) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        let request = ChatCompletionRequest(
            model: model, messages: messages, stream: true,
            maxTokens: options.maxOutputTokens, temperature: options.temperature ?? 0.7,
            tools: tools, toolChoice: tools != nil ? (options.toolChoice ?? "auto") : nil,
            streamOptions: .init(includeUsage: true),
            reasoningEffort: options.reasoningEffort
        )
        let requestData = try JSONEncoder().encode(request)
        let urlRequest = buildURLRequest(
            url: URL(string: Self.chatEndpoint)!, token: token, body: requestData,
            model: model, messages: messages)
        let bytes = try await SSEParser.validatedBytes(for: urlRequest, session: SSEParser.urlSession)
        return SSEParser.parseChatCompletionsStream(bytes: bytes)
    }

    // MARK: - Responses API Stream

    private func streamResponsesAPI(
        messages: [APIMessage], model: String, tools: [APITool]?,
        options: ProviderOptions, token: String
    ) async throws -> AsyncThrowingStream<ProviderEvent, Error> {
        let input = Self.convertToResponsesInput(messages: messages)
        let apiTools: [ResponsesAPITool]? = tools?.map { tool in
            ResponsesAPITool(type: "function", name: tool.function.name,
                             description: tool.function.description, parameters: tool.function.parameters)
        }
        let request = ResponsesAPIRequest(
            model: model, instructions: options.systemPrompt ?? "",
            input: input, stream: true, maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature ?? 0.7,
            tools: apiTools, toolChoice: apiTools != nil ? (options.toolChoice ?? "auto") : nil
        )
        let requestData = try JSONEncoder().encode(request)
        let urlRequest = buildURLRequest(
            url: URL(string: Self.responsesEndpoint)!, token: token, body: requestData,
            model: model, messages: messages)
        let bytes = try await SSEParser.validatedBytes(for: urlRequest, session: SSEParser.urlSession)
        return SSEParser.parseResponsesStream(bytes: bytes)
    }

    // MARK: - Helpers

    /// Build request with headers matching OpenCode TS version.
    /// Uses raw GitHub OAuth token directly (no token exchange needed).
    private func buildURLRequest(
        url: URL, token: String, body: Data,
        model: String = "", messages: [APIMessage] = []
    ) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("conversation-edits", forHTTPHeaderField: "Openai-Intent")

        // Agent vs user initiator (TS version behavior)
        let initiator = Self.isAgentInitiated(messages: messages) ? "agent" : "user"
        urlRequest.setValue(initiator, forHTTPHeaderField: "x-initiator")

        // Vision header when images are present
        if Self.hasVisionContent(messages: messages) {
            urlRequest.setValue("true", forHTTPHeaderField: "Copilot-Vision-Request")
        }

        // Anthropic thinking header for Claude models
        if model.lowercased().contains("claude") {
            urlRequest.setValue(
                "interleaved-thinking-2025-05-14",
                forHTTPHeaderField: "anthropic-beta")
        }

        urlRequest.httpBody = body
        return urlRequest
    }

    private static func convertToResponsesInput(messages: [APIMessage]) -> [ResponsesInputItem] {
        SSEParser.convertToResponsesInput(messages: messages)
    }
}

// Uses shared OpenAIChatResponse from ChatModels.swift
