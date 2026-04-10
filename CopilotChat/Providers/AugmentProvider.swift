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
                    let thinkingStartTag = "<thinking>"
                    let thinkingEndTag = "</thinking>"
                    var bufferedText = ""
                    var isInsideThinkingBlock = false

                    func flushBufferedText(_ incoming: String? = nil, final: Bool = false) {
                        if let incoming {
                            bufferedText += incoming
                        }

                        while !bufferedText.isEmpty {
                            if isInsideThinkingBlock {
                                if let endRange = bufferedText.range(of: thinkingEndTag) {
                                    let reasoning = String(bufferedText[..<endRange.lowerBound])
                                    if !reasoning.isEmpty {
                                        continuation.yield(.thinkingDelta(reasoning))
                                    }
                                    bufferedText = String(bufferedText[endRange.upperBound...])
                                    isInsideThinkingBlock = false
                                    continue
                                }

                                if final {
                                    continuation.yield(.thinkingDelta(bufferedText))
                                    bufferedText = ""
                                    break
                                }

                                let split = Self.splitStreamingBuffer(
                                    bufferedText,
                                    preservingPossiblePrefixOf: thinkingEndTag
                                )
                                if !split.emit.isEmpty {
                                    continuation.yield(.thinkingDelta(split.emit))
                                }
                                bufferedText = split.keep
                                break
                            }

                            if let startRange = bufferedText.range(of: thinkingStartTag) {
                                let content = String(bufferedText[..<startRange.lowerBound])
                                if !content.isEmpty {
                                    continuation.yield(.contentDelta(content))
                                }
                                bufferedText = String(bufferedText[startRange.upperBound...])
                                isInsideThinkingBlock = true
                                continue
                            }

                            if final {
                                continuation.yield(.contentDelta(bufferedText))
                                bufferedText = ""
                                break
                            }

                            let split = Self.splitStreamingBuffer(
                                bufferedText,
                                preservingPossiblePrefixOf: thinkingStartTag
                            )
                            if !split.emit.isEmpty {
                                continuation.yield(.contentDelta(split.emit))
                            }
                            bufferedText = split.keep
                            break
                        }
                    }

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
                            flushBufferedText(text)
                        }

                        // Parse tool call nodes
                        if let nodes = json["nodes"] as? [[String: Any]] {
                            for node in nodes {
                                parseNode(node, continuation: continuation)
                            }
                        }

                        // stop_reason is usually an integer: 1 = end_turn, 3 = tool_use
                        if let stopReason = json["stop_reason"] as? Int {
                            let reason: ChatMessage.FinishReason = (stopReason == 3) ? .toolCalls : .stop
                            continuation.yield(.finish(reason: reason))
                        } else if let stopReason = json["stop_reason"] as? String, !stopReason.isEmpty {
                            let reason: ChatMessage.FinishReason =
                                stopReason == "tool_use" ? .toolCalls : .stop
                            continuation.yield(.finish(reason: reason))
                        }
                    }

                    flushBufferedText(final: true)
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
        var content = ""
        var toolCalls: [String: (id: String, name: String, arguments: String)] = [:]
        var finishReason: ChatMessage.FinishReason?

        let stream = streamCompletion(messages: messages, model: model, tools: tools, options: options)
        for try await event in stream {
            switch event {
            case .contentDelta(let text):
                content += text
            case .toolCallStart(let idx, let id, let name):
                let key = "\(idx)"
                toolCalls[key] = (id: id, name: name, arguments: "")
            case .toolCallDelta(let idx, let arguments):
                let key = "\(idx)"
                if toolCalls[key] != nil {
                    toolCalls[key]?.arguments += arguments
                }
            case .toolCallStop(let idx):
                _ = idx
            case .finish(let reason):
                finishReason = reason
            default:
                break
            }
        }

        let sortedToolCalls = toolCalls.sorted(by: { $0.key < $1.key }).map { _, value in
            ToolCall(id: value.id, function: .init(name: value.name, arguments: value.arguments))
        }

        return ProviderResponse(
            content: content.isEmpty ? nil : content,
            toolCalls: sortedToolCalls,
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
            extraHeaders: [
                "x-request-id": UUID().uuidString,
                "X-Mode": "sdk",
            ]
        )
    }

    private func buildRequestBody(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> [String: Any] {
        var requestMessages = messages
        if let systemText = options.systemPrompt, !systemText.isEmpty,
           !requestMessages.contains(where: { $0.role == "system" }) {
            requestMessages.insert(APIMessage(role: "system", content: systemText), at: 0)
        }

        let (chatHistory, nodes) = convertMessages(requestMessages)

        let body: [String: Any] = [
            "model": model,
            "message": "",  // Always empty; user text goes in nodes.
            "chat_history": chatHistory,
            "mode": "CLI_AGENT",
            "blobs": ["checkpoint_id": NSNull(), "added_blobs": [], "deleted_blobs": []],
            "user_guided_blobs": [],
            "external_source_ids": [],
            "nodes": nodes,
            "tool_definitions": convertTools(tools),
            "rules": [],
            "skills": [],
            "silent": false,
            "enable_parallel_tool_use": false,
            "feature_detection_flags": [
                "support_tool_use_start": true,
                "support_parallel_tool_use": false,
            ] as [String: Any],
        ]

        return body
    }

    // MARK: - Message Conversion

    /// Convert APIMessages to Augment's exchange-based format.
    private func convertMessages(_ messages: [APIMessage]) -> (chatHistory: [[String: Any]], nodes: [[String: Any]]) {
        var chatHistory: [[String: Any]] = []
        var pendingRequestNodes: [[String: Any]] = []
        var pendingRequestText = ""
        var nodeId = 1

        func appendRequestText(_ text: String) {
            guard !text.isEmpty else { return }
            if pendingRequestText.isEmpty {
                pendingRequestText = text
            } else {
                pendingRequestText += "\n" + text
            }
        }

        func appendTextRequestNode(_ text: String) {
            guard !text.isEmpty else { return }
            pendingRequestNodes.append([
                "id": nodeId,
                "type": 0,
                "text_node": ["content": text],
            ])
            nodeId += 1
            appendRequestText(text)
        }

        func appendToolResultNode(_ msg: APIMessage) {
            pendingRequestNodes.append([
                "id": nodeId,
                "type": 1,
                "tool_result_node": [
                    "tool_use_id": msg.toolCallId ?? "",
                    "content": msg.content ?? "",
                    "is_error": false,
                ] as [String: Any],
            ])
            nodeId += 1
        }

        func finalizeAssistantTurn(_ msg: APIMessage) {
            let responseNodes = assistantResponseNodes(content: msg.content, reasoning: msg.reasoning)
            var responseNodesWithTools = responseNodes

            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                for toolCall in toolCalls {
                    responseNodesWithTools.append([
                        "id": nodeId,
                        "type": 5,
                        "content": "",
                        "tool_use": [
                            "tool_use_id": toolCall.id,
                            "tool_name": toolCall.function.name,
                            "input_json": toolCall.function.arguments,
                            "is_partial": false,
                        ] as [String: Any],
                        "thinking": NSNull(),
                        "billing_metadata": NSNull(),
                        "metadata": NSNull(),
                        "token_usage": NSNull(),
                    ])
                    nodeId += 1
                }
            }

            chatHistory.append([
                "request_message": pendingRequestText,
                "response_text": msg.content ?? "",
                "request_id": UUID().uuidString,
                "request_nodes": pendingRequestNodes,
                "response_nodes": responseNodesWithTools,
                "token_usage": ["input_tokens": 0, "output_tokens": 0],
                "total_tokens": 0,
            ] as [String: Any])

            pendingRequestNodes = []
            pendingRequestText = ""
            nodeId = 1
        }

        func assistantResponseNodes(content: String?, reasoning: String?) -> [[String: Any]] {
            var responseNodes: [[String: Any]] = []

            if let content, !content.isEmpty {
                responseNodes.append([
                    "id": nodeId,
                    "type": 0,
                    "content": content,
                    "thinking": NSNull(),
                    "billing_metadata": NSNull(),
                    "metadata": NSNull(),
                    "token_usage": NSNull(),
                ])
                nodeId += 1
            }

            if let reasoning, !reasoning.isEmpty {
                responseNodes.append([
                    "id": nodeId,
                    "type": 8,
                    "content": "",
                    "thinking": ["text": reasoning],
                    "billing_metadata": NSNull(),
                    "metadata": NSNull(),
                    "token_usage": NSNull(),
                ])
                nodeId += 1
            }

            return responseNodes
        }

        var i = 0
        while i < messages.count {
            let msg = messages[i]

            switch msg.role {
            case "system":
                if let systemText = msg.content, !systemText.isEmpty {
                    appendTextRequestNode("System: \(systemText)")
                }
            case "user":
                appendTextRequestNode(msg.content ?? "")
            case "tool":
                appendToolResultNode(msg)
            case "assistant":
                finalizeAssistantTurn(msg)
            default:
                break
            }

            i += 1
        }

        if pendingRequestNodes.isEmpty {
            pendingRequestNodes.append(["id": 1, "type": 0, "text_node": ["content": ""]])
        }

        return (chatHistory, pendingRequestNodes)
    }

    /// Convert APITools to Augment's tool_definitions format.
    /// Augment expects `input_schema_json` as a stringified JSON schema.
    private func convertTools(_ tools: [APITool]?) -> [[String: Any]] {
        guard let tools else { return [] }
        return tools.map { tool in
            var def: [String: Any] = [
                "name": tool.function.name,
                "description": tool.function.description,
                "tool_safety": 0,
            ]
            if let params = tool.function.parameters {
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

    private static func splitStreamingBuffer(
        _ buffer: String,
        preservingPossiblePrefixOf tag: String
    ) -> (emit: String, keep: String) {
        guard !buffer.isEmpty, !tag.isEmpty else { return (buffer, "") }

        let maxPrefixLength = min(buffer.count, tag.count - 1)
        if maxPrefixLength <= 0 {
            return (buffer, "")
        }

        for prefixLength in stride(from: maxPrefixLength, through: 1, by: -1) {
            let prefix = String(tag.prefix(prefixLength))
            if buffer.hasSuffix(prefix) {
                let splitIndex = buffer.index(buffer.endIndex, offsetBy: -prefixLength)
                return (String(buffer[..<splitIndex]), String(buffer[splitIndex...]))
            }
        }

        return (buffer, "")
    }

    /// Parse an NDJSON node. Type 7 = tool_use_start, type 5 = tool_use complete,
    /// type 8 = thinking, type 10 = usage.
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
        case 5: // tool_use complete
            if let toolUse = node["tool_use"] as? [String: Any],
               let inputJson = toolUse["input_json"] as? String {
                let index = node["id"] as? Int ?? 0
                continuation.yield(.toolCallDelta(index: index, arguments: inputJson))
                continuation.yield(.toolCallStop(index: index))
            }
        case 8: // Thinking
            if let thinking = node["thinking"] as? [String: Any],
               let text = (thinking["text"] as? String) ??
                   (thinking["content"] as? String) ??
                   (thinking["summary"] as? String),
               !text.isEmpty {
                continuation.yield(.thinkingDelta(text))
            }
        case 10: // Token usage
            if let usage = node["token_usage"] as? [String: Any] {
                let inputTokens = usage["input_tokens"] as? Int
                let historyTokens = usage["chat_history_tokens"] as? Int ?? 0
                let currentMessageTokens = usage["current_message_tokens"] as? Int ?? 0
                let toolDefinitionTokens = usage["tool_definitions_tokens"] as? Int ?? 0
                let toolResultTokens = usage["tool_result_tokens"] as? Int ?? 0
                let systemPromptTokens = usage["system_prompt_tokens"] as? Int ?? 0
                let prompt = inputTokens ?? (
                    historyTokens + currentMessageTokens + toolDefinitionTokens + toolResultTokens + systemPromptTokens
                )
                let completion = (usage["output_tokens"] as? Int)
                    ?? (usage["assistant_response_tokens"] as? Int)
                    ?? 0
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
