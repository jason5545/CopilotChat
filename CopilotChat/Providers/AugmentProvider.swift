import Foundation

// MARK: - Augment Code Provider

/// Provider for Augment Code's proprietary NDJSON streaming API.
/// Augment uses a custom chat-stream endpoint (NOT OpenAI-compatible).
struct AugmentProvider: LLMProvider, @unchecked Sendable {
    let id = "augment"
    let displayName = "Augment Code"

    private let baseURL: String
    private let apiKey: String

    init(baseURL: String, apiKey: String) {
        // Strip trailing slash for consistent URL building
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
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
                    let body = buildRequestBody(messages: messages, model: model, tools: tools, options: options)
                    let requestData = try JSONSerialization.data(withJSONObject: body)
                    let urlRequest = buildURLRequest(body: requestData)

                    let bytes = try await SSEParser.validatedBytes(
                        for: urlRequest, session: SSEParser.urlSession)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Emit text content delta
                        if let text = json["text"] as? String, !text.isEmpty {
                            continuation.yield(.contentDelta(text))
                        }

                        // Parse tool call nodes (type 2)
                        if let nodes = json["nodes"] as? [[String: Any]] {
                            for node in nodes {
                                parseNode(node, continuation: continuation)
                            }
                        }

                        // Check for stop_reason on final chunk
                        if let stopReason = json["stop_reason"] as? String {
                            let reason: ChatMessage.FinishReason =
                                stopReason == "tool_use" ? .toolCalls : .stop
                            continuation.yield(.finish(reason: reason))
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
        // Accumulate streamed chunks into a single response
        var content = ""
        var toolCalls: [ToolCall] = []
        var finishReason: ChatMessage.FinishReason?

        let stream = streamCompletion(messages: messages, model: model, tools: tools, options: options)
        for try await event in stream {
            switch event {
            case .contentDelta(let text):
                content += text
            case .toolCallStop(let index):
                // Tool calls accumulated via start/delta below
                _ = index
            case .finish(let reason):
                finishReason = reason
            default:
                break
            }
        }

        return ProviderResponse(
            content: content.isEmpty ? nil : content,
            toolCalls: toolCalls,
            finishReason: finishReason
        )
    }

    // MARK: - Request Building

    private func buildURLRequest(body: Data) -> URLRequest {
        let url = URL(string: "\(baseURL)/chat-stream")!
        return SSEParser.buildRequest(
            url: url,
            apiKey: apiKey,
            body: body,
            extraHeaders: ["x-request-id": UUID().uuidString]
        )
    }

    private func buildRequestBody(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> [String: Any] {
        let (message, chatHistory) = convertMessages(messages)

        var body: [String: Any] = [
            "model": model,
            "message": message,
            "chat_history": chatHistory,
            "mode": "CHAT",
            "blobs": ["checkpoint_id": NSNull(), "added_blobs": [], "deleted_blobs": []],
            "user_guided_blobs": [],
            "external_source_ids": [],
            "nodes": [],
            "tool_definitions": convertTools(tools),
            "rules": [],
            "skills": [],
            "silent": false,
            "enable_parallel_tool_use": false,
            "feature_detection_flags": [String: Any](),
        ]

        if let systemPrompt = options.systemPrompt {
            body["system_prompt"] = systemPrompt
        }

        return body
    }

    // MARK: - Message Conversion

    /// Convert APIMessages to Augment's format:
    /// - Last user message becomes the top-level "message" field
    /// - All previous messages become "chat_history" entries
    private func convertMessages(_ messages: [APIMessage]) -> (String, [[String: String]]) {
        var chatHistory: [[String: String]] = []
        var lastUserMessage = ""

        for msg in messages {
            let text = msg.content ?? ""
            switch msg.role {
            case "system":
                chatHistory.append(["role": "system", "message": text])
            case "user":
                // If we already have a user message queued, push it to history
                if !lastUserMessage.isEmpty {
                    chatHistory.append(["role": "user", "message": lastUserMessage])
                }
                lastUserMessage = text
            case "assistant":
                chatHistory.append(["role": "assistant", "message": text])
            case "tool":
                // Include tool results as assistant context in history
                let toolContent = "Tool result (\(msg.toolCallId ?? "unknown")): \(text)"
                chatHistory.append(["role": "assistant", "message": toolContent])
            default:
                chatHistory.append(["role": msg.role, "message": text])
            }
        }

        return (lastUserMessage, chatHistory)
    }

    /// Convert APITools to Augment's tool_definitions format.
    private func convertTools(_ tools: [APITool]?) -> [[String: Any]] {
        guard let tools else { return [] }
        return tools.map { tool in
            var def: [String: Any] = [
                "name": tool.function.name,
                "description": tool.function.description,
            ]
            if let params = tool.function.parameters {
                // Convert AnyCodable parameters to raw dictionary
                var rawParams: [String: Any] = [:]
                for (key, value) in params {
                    rawParams[key] = value.value
                }
                def["parameters"] = rawParams
            }
            return def
        }
    }

    // MARK: - Node Parsing

    /// Parse an NDJSON node. Type 2 = tool call, type 8 = thinking, type 10 = usage.
    private func parseNode(_ node: [String: Any], continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation) {
        guard let type = node["type"] as? Int else { return }

        switch type {
        case 2: // Tool call
            if let toolUse = node["tool_use"] as? [String: Any],
               let toolId = toolUse["id"] as? String,
               let toolName = toolUse["tool_name"] as? String {
                continuation.yield(.toolCallStart(index: 0, id: toolId, name: toolName))
                if let input = toolUse["input"] as? String {
                    continuation.yield(.toolCallDelta(index: 0, arguments: input))
                }
                continuation.yield(.toolCallStop(index: 0))
            }
        case 8: // Thinking
            if let text = node["text"] as? String, !text.isEmpty {
                continuation.yield(.thinkingDelta(text))
            }
        case 10: // Token usage
            if let usage = node["usage"] as? [String: Any] {
                let prompt = usage["input_tokens"] as? Int ?? 0
                let completion = usage["output_tokens"] as? Int ?? 0
                continuation.yield(.usage(TokenUsage(
                    promptTokens: prompt,
                    completionTokens: completion,
                    totalTokens: prompt + completion
                )))
            }
        default:
            break
        }
    }
}
