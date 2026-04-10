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

                        // stop_reason is an integer: 1 = end_turn, 3 = tool_use
                        if let stopReason = json["stop_reason"] as? Int {
                            let reason: ChatMessage.FinishReason = (stopReason == 3) ? .toolCalls : .stop
                            continuation.yield(.finish(reason: reason))
                        } else if let stopReason = json["stop_reason"] as? String, !stopReason.isEmpty {
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
            "feature_detection_flags": ["support_tool_use_start": true, "support_parallel_tool_use": false] as [String: Any],
        ]


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
                break  // Augment manages its own system prompt
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
    /// Augment expects a flat structure with `input_schema_json` as a **stringified** JSON string.
    private func convertTools(_ tools: [APITool]?) -> [[String: Any]] {
        guard let tools else { return [] }
        return tools.map { tool in
            var def: [String: Any] = [
                "name": tool.function.name,
                "description": tool.function.description,
                "tool_safety": 0,
            ]
            if let params = tool.function.parameters {
                // Convert AnyCodable parameters to raw dictionary, then stringify
                var rawParams: [String: Any] = [:]
                for (key, value) in params {
                    rawParams[key] = value.value
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: rawParams),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    def["input_schema_json"] = jsonString
                }
            }
            return def
        }
    }

    // MARK: - Node Parsing

    /// Parse an NDJSON node. Type 7 = tool_use_start, type 5 = tool_use complete, type 8 = thinking, type 10 = usage.
    private func parseNode(_ node: [String: Any], continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation) {
        guard let nodeType = node["type"] as? Int else { return }

        switch nodeType {
        case 7: // tool_use_start
            if let toolUse = node["tool_use"] as? [String: Any],
               let toolId = toolUse["tool_use_id"] as? String,
               let toolName = toolUse["tool_name"] as? String {
                let index = node["id"] as? Int ?? 0
                continuation.yield(.toolCallStart(index: index, id: toolId, name: toolName))
            }
        case 5: // tool_use (complete with input)
            if let toolUse = node["tool_use"] as? [String: Any],
               let inputJson = toolUse["input_json"] as? String {
                let index = node["id"] as? Int ?? 0
                continuation.yield(.toolCallDelta(index: index, arguments: inputJson))
                continuation.yield(.toolCallStop(index: index))
            }
        case 8: // thinking
            if let thinking = node["thinking"] as? [String: Any],
               let text = thinking["text"] as? String, !text.isEmpty {
                continuation.yield(.thinkingDelta(text))
            }
        case 10: // token usage
            if let usage = node["token_usage"] as? [String: Any] {
                let inputTokens = usage["input_tokens"] as? Int ?? 0
                let outputTokens = usage["output_tokens"] as? Int ?? 0
                continuation.yield(.usage(TokenUsage(
                    promptTokens: inputTokens,
                    completionTokens: outputTokens,
                    totalTokens: inputTokens + outputTokens
                )))
            }
        default:
            break
        }
    }
}
