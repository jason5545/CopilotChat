import Foundation

// MARK: - Anthropic-Compatible Provider

/// Provider for Anthropic Messages API format.
/// Covers: Anthropic (direct), MiniMax (international & CN), MiniMax Coding Plan.
/// MiniMax uses the same Anthropic Messages API at their own endpoints.
struct AnthropicCompatibleProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let baseURL: String
    let apiKey: String

    private static let defaultBaseURL = "https://api.anthropic.com"
    private static let apiVersion = "2023-06-01"

    init(
        id: String = "anthropic",
        displayName: String = "Anthropic",
        baseURL: String = "https://api.anthropic.com",
        apiKey: String
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
    }

    /// Create from a models.dev provider entry.
    init?(provider: ModelsDevProvider, apiKey: String) {
        guard let api = provider.api, !api.isEmpty else {
            // Anthropic direct — use default base URL
            self.init(id: provider.id, displayName: provider.name,
                      baseURL: Self.defaultBaseURL, apiKey: apiKey)
            return
        }
        self.init(id: provider.id, displayName: provider.name, baseURL: api, apiKey: apiKey)
    }

    // MARK: - Endpoints

    private var messagesURL: URL {
        let base = baseURL
        if base.contains("/messages") {
            return URL(string: base)!
        }
        if base.hasSuffix("/v1") {
            return URL(string: "\(base)/messages")!
        }
        return URL(string: "\(base)/v1/messages")!
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
                    let (system, anthropicMessages) = convertMessages(messages)
                    let anthropicTools = tools.map { convertTools($0) }

                    let thinkingConfig = ProviderTransform.anthropicThinkingConfig(
                        modelId: model, model: nil, effort: options.reasoningEffort)

                    let body = AnthropicRequest(
                        model: model,
                        messages: anthropicMessages,
                        system: options.systemPrompt ?? system,
                        maxTokens: options.maxOutputTokens ?? 8192,
                        temperature: options.temperature ?? 0.7,
                        topP: options.topP, topK: options.topK,
                        stream: true,
                        tools: anthropicTools,
                        thinking: thinkingConfig
                    )

                    let requestData = try JSONEncoder().encode(body)
                    let urlRequest = buildRequest(body: requestData)
                    let bytes = try await SSEParser.validatedBytes(
                        for: urlRequest, session: SSEParser.urlSession)

                    let stream = parseAnthropicSSE(bytes: bytes)
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
        let (system, anthropicMessages) = convertMessages(messages)
        let anthropicTools = tools.map { convertTools($0) }
        let thinkingConfig = ProviderTransform.anthropicThinkingConfig(
            modelId: model, model: nil, effort: options.reasoningEffort)

        let body = AnthropicRequest(
            model: model,
            messages: anthropicMessages,
            system: options.systemPrompt ?? system,
            maxTokens: options.maxOutputTokens ?? 8192,
            temperature: options.temperature ?? 0.7,
            topP: options.topP, topK: options.topK,
            stream: false,
            tools: anthropicTools,
            thinking: thinkingConfig
        )

        let requestData = try JSONEncoder().encode(body)
        let urlRequest = buildRequest(body: requestData)

        let (data, response) = try await SSEParser.urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.invalidResponse(statusCode: code, body: body)
        }

        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return decoded.toProviderResponse()
    }

    // MARK: - Request Building

    private func buildRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CopilotChat/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        // Anthropic uses x-api-key, not Authorization Bearer
        if baseURL.contains("anthropic.com") {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue(
                "interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14",
                forHTTPHeaderField: "anthropic-beta")
        } else {
            // MiniMax and others use Bearer token with Anthropic API format
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    // MARK: - Message Conversion

    /// Convert OpenAI-format APIMessages to Anthropic format.
    /// Returns (system prompt, messages array).
    private func convertMessages(_ messages: [APIMessage]) -> (String?, [AnthropicMessage]) {
        var systemPrompt: String?
        var result: [AnthropicMessage] = []

        for msg in messages {
            switch msg.role {
            case "system":
                systemPrompt = msg.content
            case "user":
                result.append(AnthropicMessage(
                    role: "user",
                    content: [.init(type: "text", text: msg.content ?? "")]))
            case "assistant":
                var blocks: [AnthropicContentBlock] = []
                if let content = msg.content, !content.isEmpty {
                    blocks.append(.init(type: "text", text: content))
                }
                if let toolCalls = msg.toolCalls {
                    for call in toolCalls {
                        blocks.append(.init(
                            type: "tool_use", id: call.id,
                            name: call.function.name,
                            input: parseJSON(call.function.arguments)))
                    }
                }
                if !blocks.isEmpty {
                    result.append(AnthropicMessage(role: "assistant", content: blocks))
                }
            case "tool":
                if let callId = msg.toolCallId {
                    result.append(AnthropicMessage(
                        role: "user",
                        content: [.init(
                            type: "tool_result",
                            toolUseId: callId,
                            content: msg.content)]))
                }
            default:
                break
            }
        }

        return (systemPrompt, result)
    }

    private func convertTools(_ tools: [APITool]) -> [AnthropicTool] {
        tools.map { tool in
            let schema: AnyCodable
            if let p = tool.function.parameters {
                schema = AnyCodable(p.mapValues { $0.value })
            } else {
                schema = AnyCodable([:])
            }
            return AnthropicTool(
                name: tool.function.name,
                description: tool.function.description,
                inputSchema: schema)
        }
    }

    private func parseJSON(_ jsonString: String) -> AnyCodable {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return AnyCodable([:])
        }
        return AnyCodable(obj)
    }

    // MARK: - Anthropic SSE Parsing

    private func parseAnthropicSSE(
        bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let decoder = JSONDecoder()
                    var currentEventType: String?
                    var currentToolCallId = ""
                    var toolCallIndex = 0

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        if line.hasPrefix("event: ") {
                            currentEventType = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                            continue
                        }

                        guard line.hasPrefix("data: "),
                              let eventType = currentEventType else { continue }
                        let payload = String(line.dropFirst(6))
                        currentEventType = nil

                        guard let data = payload.data(using: .utf8) else { continue }

                        switch eventType {
                        case "content_block_start":
                            if let evt = try? decoder.decode(AnthropicSSEEvent.self, from: data),
                               let block = evt.contentBlock {
                                if block.type == "tool_use" {
                                    currentToolCallId = block.id ?? ""
                                    continuation.yield(.toolCallStart(
                                        index: toolCallIndex,
                                        id: currentToolCallId,
                                        name: block.name ?? ""))
                                    toolCallIndex += 1
                                }
                            }

                        case "content_block_delta":
                            if let evt = try? decoder.decode(AnthropicSSEEvent.self, from: data),
                               let delta = evt.delta {
                                if delta.type == "text_delta", let text = delta.text {
                                    continuation.yield(.contentDelta(text))
                                } else if delta.type == "thinking_delta", let thinking = delta.thinking {
                                    continuation.yield(.thinkingDelta(thinking))
                                } else if delta.type == "input_json_delta", let json = delta.partialJson {
                                    continuation.yield(.toolCallDelta(
                                        index: max(0, toolCallIndex - 1), arguments: json))
                                }
                            }

                        case "content_block_stop":
                            if !currentToolCallId.isEmpty {
                                continuation.yield(.toolCallStop(index: max(0, toolCallIndex - 1)))
                                currentToolCallId = ""
                            }

                        case "message_delta":
                            if let evt = try? decoder.decode(AnthropicSSEEvent.self, from: data),
                               let delta = evt.delta {
                                if let usage = evt.usage {
                                    continuation.yield(.usage(TokenUsage(
                                        promptTokens: usage.inputTokens ?? 0,
                                        completionTokens: usage.outputTokens ?? 0,
                                        totalTokens: (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0))))
                                }
                                if let stopReason = delta.stopReason {
                                    let reason: ChatMessage.FinishReason
                                    switch stopReason {
                                    case "end_turn": reason = .stop
                                    case "max_tokens": reason = .length
                                    case "tool_use": reason = .toolCalls
                                    default: reason = .stop
                                    }
                                    continuation.yield(.finish(reason: reason))
                                }
                            }

                        case "message_stop":
                            break // stream done

                        case "error":
                            if let evt = try? decoder.decode(AnthropicSSEEvent.self, from: data),
                               let error = evt.error {
                                continuation.finish(throwing: ProviderError.streamingFailed(
                                    "\(error.type ?? "unknown"): \(error.message ?? "")"))
                                return
                            }

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
}

// MARK: - Anthropic API Types

private struct AnthropicRequest: Encodable {
    let model: String
    let messages: [AnthropicMessage]
    let system: String?
    let maxTokens: Int
    let temperature: Double
    let topP: Double?
    let topK: Int?
    let stream: Bool
    let tools: [AnthropicTool]?
    /// Thinking config: { type: "adaptive", effort: "..." } or { type: "enabled", budgetTokens: N }
    let thinking: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case model, messages, system, temperature, stream, tools, thinking
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
    }
}

private struct AnthropicMessage: Codable {
    let role: String
    let content: [AnthropicContentBlock]
}

private struct AnthropicContentBlock: Codable {
    let type: String
    var text: String?
    var id: String?
    var name: String?
    var input: AnyCodable?
    var toolUseId: String?
    var content: String?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseId = "tool_use_id"
    }
}

private struct AnthropicTool: Encodable {
    let name: String
    let description: String?
    let inputSchema: AnyCodable

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

private struct AnthropicResponse: Codable {
    let content: [AnthropicResponseBlock]?
    let stopReason: String?
    let usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }

    func toProviderResponse() -> ProviderResponse {
        var text = ""
        var toolCalls: [ToolCall] = []

        for block in content ?? [] {
            if block.type == "text", let t = block.text {
                text += t
            } else if block.type == "tool_use", let id = block.id, let name = block.name {
                let args = block.input.flatMap {
                    try? String(data: JSONEncoder().encode($0), encoding: .utf8)
                } ?? "{}"
                toolCalls.append(ToolCall(id: id, function: .init(name: name, arguments: args)))
            }
        }

        let finishReason: ChatMessage.FinishReason? = {
            switch stopReason {
            case "end_turn": return .stop
            case "max_tokens": return .length
            case "tool_use": return .toolCalls
            default: return nil
            }
        }()

        let tokenUsage = usage.map {
            TokenUsage(
                promptTokens: $0.inputTokens ?? 0,
                completionTokens: $0.outputTokens ?? 0,
                totalTokens: ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0))
        }

        return ProviderResponse(
            content: text.isEmpty ? nil : text,
            toolCalls: toolCalls,
            usage: tokenUsage,
            finishReason: finishReason
        )
    }
}

private struct AnthropicResponseBlock: Codable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: AnyCodable?
}

private struct AnthropicUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - Anthropic SSE Event Types

private struct AnthropicSSEEvent: Codable {
    let type: String?
    let delta: AnthropicDelta?
    let contentBlock: AnthropicSSEContentBlock?
    let usage: AnthropicUsage?
    let error: AnthropicError?

    enum CodingKeys: String, CodingKey {
        case type, delta, usage, error
        case contentBlock = "content_block"
    }
}

private struct AnthropicDelta: Codable {
    let type: String?
    let text: String?
    let thinking: String?
    let partialJson: String?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking
        case partialJson = "partial_json"
        case stopReason = "stop_reason"
    }
}

private struct AnthropicSSEContentBlock: Codable {
    let type: String?
    let id: String?
    let name: String?
}

private struct AnthropicError: Codable {
    let type: String?
    let message: String?
}
