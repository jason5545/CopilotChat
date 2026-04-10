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
        var (chatHistory, nodes) = convertMessages(messages)

        // Inject system prompt as a synthetic first exchange.
        // Augment rejects the `system_prompt` field, but respects instructions
        // given as a fake first user message in chat_history.
        // options.systemPrompt takes precedence; system messages from the
        // messages array are appended after it.
        if let systemText = options.systemPrompt, !systemText.isEmpty {
            let sysExchange: [String: Any] = [
                "request_message": "" as Any,
                "response_text": "Understood." as Any,
                "request_id": "system-prompt" as Any,
                "request_nodes": [
                    ["id": 1, "type": 0, "text_node": ["content": systemText]]
                ] as Any,
                "response_nodes": [] as [[String: Any]] as Any,
                "token_usage": ["input_tokens": 0, "output_tokens": 0] as Any,
                "total_tokens": 0 as Any,
            ]
            chatHistory.insert(sysExchange, at: 0)
        }

        let body: [String: Any] = [
            "model": model,
            "message": "",  // Always empty — user text goes in nodes as type 0 text_node
            "chat_history": chatHistory,
            "mode": "CHAT",
            "blobs": ["checkpoint_id": NSNull(), "added_blobs": [], "deleted_blobs": []],
            "user_guided_blobs": [],
            "external_source_ids": [],
            "nodes": nodes,
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

    /// Convert APIMessages to Augment's exchange-based chat_history format.
    ///
    /// Key rules (verified against actual Augment API):
    /// - `message` is ALWAYS "" (empty string); user text goes in a type 0 text_node in `nodes`
    /// - `chat_history` entries are exchange objects with request_nodes / response_nodes
    /// - Tool calls from the assistant become response_nodes with type 5 tool_use nodes
    /// - Tool results become type 1 tool_result_node entries in the current request's `nodes`
    private func convertMessages(_ messages: [APIMessage]) -> (chatHistory: [[String: Any]], nodes: [[String: Any]]) {
        var chatHistory: [[String: Any]] = []
        var currentNodes: [[String: Any]] = []
        var nodeId = 1

        var i = 0
        while i < messages.count {
            let msg = messages[i]

            if msg.role == "system" {
                i += 1
                continue
            }

            if msg.role == "user" {
                let userText = msg.content ?? ""
                let userNode: [String: Any] = ["id": nodeId, "type": 0, "text_node": ["content": userText]]
                nodeId += 1

                // Check if next message is assistant (this user+assistant pair becomes a chat_history exchange)
                if i + 1 < messages.count && messages[i + 1].role == "assistant" {
                    let assistant = messages[i + 1]
                    let assistantText = assistant.content ?? ""

                    if let toolCalls = assistant.toolCalls, !toolCalls.isEmpty {
                        // Assistant responded with tool calls → build response_nodes with type 5 tool_use
                        var responseNodes: [[String: Any]] = []
                        if !assistantText.isEmpty {
                            responseNodes.append(["id": nodeId, "type": 0, "content": assistantText,
                                                   "thinking": NSNull(), "billing_metadata": NSNull(),
                                                   "metadata": NSNull(), "token_usage": NSNull()])
                            nodeId += 1
                        }
                        for tc in toolCalls {
                            let toolNode: [String: Any] = [
                                "id": nodeId, "type": 5, "content": "",
                                "tool_use": [
                                    "tool_use_id": tc.id,
                                    "tool_name": tc.function.name,
                                    "input_json": tc.function.arguments,
                                    "is_partial": false,
                                ] as [String: Any],
                                "thinking": NSNull(), "billing_metadata": NSNull(),
                                "metadata": NSNull(), "token_usage": NSNull(),
                            ]
                            responseNodes.append(toolNode)
                            nodeId += 1
                        }

                        chatHistory.append([
                            "request_message": "",
                            "response_text": assistantText,
                            "request_id": UUID().uuidString,
                            "request_nodes": [userNode],
                            "response_nodes": responseNodes,
                            "token_usage": ["input_tokens": 0, "output_tokens": 0],
                            "total_tokens": 0,
                        ] as [String: Any])

                        // Process subsequent tool result messages
                        i += 2  // skip user + assistant
                        while i < messages.count && messages[i].role == "tool" {
                            let toolMsg = messages[i]
                            let toolResultNode: [String: Any] = [
                                "id": nodeId, "type": 1,
                                "tool_result_node": [
                                    "tool_use_id": toolMsg.toolCallId ?? "",
                                    "content": toolMsg.content ?? "",
                                    "is_error": false,
                                ] as [String: Any],
                            ]
                            nodeId += 1

                            // If a tool result is followed by an assistant, they form another exchange
                            if i + 1 < messages.count && messages[i + 1].role == "assistant" {
                                let nextAssistant = messages[i + 1]
                                let nextText = nextAssistant.content ?? ""

                                // Build response_nodes for this exchange (may also have tool calls)
                                var nextResponseNodes: [[String: Any]] = []
                                if let nextTCs = nextAssistant.toolCalls, !nextTCs.isEmpty {
                                    if !nextText.isEmpty {
                                        nextResponseNodes.append(["id": nodeId, "type": 0, "content": nextText,
                                                                   "thinking": NSNull(), "billing_metadata": NSNull(),
                                                                   "metadata": NSNull(), "token_usage": NSNull()])
                                        nodeId += 1
                                    }
                                    for tc in nextTCs {
                                        nextResponseNodes.append([
                                            "id": nodeId, "type": 5, "content": "",
                                            "tool_use": [
                                                "tool_use_id": tc.id,
                                                "tool_name": tc.function.name,
                                                "input_json": tc.function.arguments,
                                                "is_partial": false,
                                            ] as [String: Any],
                                            "thinking": NSNull(), "billing_metadata": NSNull(),
                                            "metadata": NSNull(), "token_usage": NSNull(),
                                        ])
                                        nodeId += 1
                                    }
                                }

                                chatHistory.append([
                                    "request_message": "",
                                    "response_text": nextText,
                                    "request_id": UUID().uuidString,
                                    "request_nodes": [toolResultNode],
                                    "response_nodes": nextResponseNodes,
                                    "token_usage": ["input_tokens": 0, "output_tokens": 0],
                                    "total_tokens": 0,
                                ] as [String: Any])
                                i += 2  // skip tool + assistant
                            } else {
                                // Last tool result(s) → current request nodes
                                currentNodes.append(toolResultNode)
                                i += 1
                            }
                        }
                        continue
                    } else {
                        // Normal user+assistant exchange (no tool calls)
                        chatHistory.append([
                            "request_message": "",
                            "response_text": assistantText,
                            "request_id": UUID().uuidString,
                            "request_nodes": [userNode],
                            "response_nodes": [] as [[String: Any]],
                            "token_usage": ["input_tokens": 0, "output_tokens": 0],
                            "total_tokens": 0,
                        ] as [String: Any])
                        i += 2
                        continue
                    }
                } else {
                    // Last user message (current turn) → goes into nodes as text_node
                    currentNodes.insert(userNode, at: 0)
                    i += 1
                    continue
                }
            }

            // Skip any orphan messages
            i += 1
        }

        // Ensure we always have at least one node
        if currentNodes.isEmpty {
            currentNodes.append(["id": 1, "type": 0, "text_node": ["content": ""]])
        }

        return (chatHistory, currentNodes)
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
