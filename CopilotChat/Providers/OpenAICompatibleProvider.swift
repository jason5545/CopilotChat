import Foundation

// MARK: - OpenAI-Compatible Provider

/// Generic provider for any API that speaks the OpenAI Chat Completions protocol.
/// Covers: Z.AI, Zhipu AI, Alibaba, Tencent, DeepSeek, OpenAI, xAI, Groq, OpenRouter,
/// OpenCode Zen, and 80+ other providers on models.dev.
struct OpenAICompatibleProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let baseURL: String
    let apiKey: String
    let extraHeaders: [String: String]

    init(
        id: String,
        displayName: String,
        baseURL: String,
        apiKey: String,
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
    }

    /// Create from a models.dev provider entry.
    init?(provider: ModelsDevProvider, apiKey: String) {
        guard let api = provider.api, !api.isEmpty else { return nil }
        self.id = provider.id
        self.displayName = provider.name
        self.baseURL = api.hasSuffix("/") ? String(api.dropLast()) : api
        self.apiKey = apiKey
        self.extraHeaders = [:]
    }

    // MARK: - Endpoints

    private func chatCompletionsURL() throws -> URL {
        let base = baseURL
        let urlString: String
        if base.hasSuffix("/chat/completions") {
            urlString = base
        } else if base.hasSuffix("/v1") || base.hasSuffix("/v3") || base.hasSuffix("/v4") {
            urlString = "\(base)/chat/completions"
        } else {
            urlString = "\(base)/chat/completions"
        }
        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidResponse(statusCode: 0, body: "Invalid base URL: \(base)")
        }
        return url
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
                    let request = ChatCompletionRequest(
                        model: model, messages: messages, stream: true,
                        maxTokens: options.maxOutputTokens,
                        temperature: options.temperature ?? 0.7,
                        topP: options.topP, topK: options.topK,
                        tools: tools,
                        toolChoice: tools != nil ? (options.toolChoice ?? "auto") : nil,
                        streamOptions: .init(includeUsage: true),
                        reasoningEffort: options.reasoningEffort,
                        extraFields: options.extraFields
                    )
                    let requestData = try JSONEncoder().encode(request)
                    let urlRequest = SSEParser.buildRequest(
                        url: try chatCompletionsURL(),
                        apiKey: apiKey,
                        body: requestData,
                        extraHeaders: extraHeaders
                    )

                    let bytes = try await SSEParser.validatedBytes(
                        for: urlRequest, session: SSEParser.urlSession)
                    let stream = SSEParser.parseChatCompletionsStream(bytes: bytes)

                    for try await event in stream {
                        continuation.yield(event)
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
        let request = ChatCompletionRequest(
            model: model, messages: messages, stream: false,
            maxTokens: options.maxOutputTokens,
            temperature: options.temperature ?? 0.7,
            topP: options.topP, topK: options.topK,
            tools: tools, toolChoice: nil,
            streamOptions: nil, reasoningEffort: options.reasoningEffort,
            extraFields: options.extraFields
        )
        let requestData = try JSONEncoder().encode(request)
        let urlRequest = SSEParser.buildRequest(
            url: try chatCompletionsURL(),
            apiKey: apiKey,
            body: requestData,
            extraHeaders: extraHeaders
        )

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
            content: content, toolCalls: toolCalls,
            usage: decoded.usage, finishReason: finishReason
        )
    }
}

// Uses shared OpenAIChatResponse from ChatModels.swift
