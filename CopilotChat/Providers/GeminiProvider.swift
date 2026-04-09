import Foundation

// MARK: - Google Gemini Provider

/// Provider for Google Gemini GenerateContent API.
/// Uses NDJSON streaming (not SSE) and a different message/tool format.
struct GeminiProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let apiKey: String

    private static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    init(id: String = "google", displayName: String = "Google Gemini", apiKey: String) {
        self.id = id
        self.displayName = displayName
        self.apiKey = apiKey
    }

    /// Create from a models.dev provider entry.
    init?(provider: ModelsDevProvider, apiKey: String) {
        self.init(id: provider.id, displayName: provider.name, apiKey: apiKey)
    }

    // MARK: - Endpoints

    private func streamURL(model: String) -> URL {
        URL(string: "\(Self.defaultBaseURL)/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)")!
    }

    private func generateURL(model: String) -> URL {
        URL(string: "\(Self.defaultBaseURL)/models/\(model):generateContent?key=\(apiKey)")!
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
                    let body = buildRequest(
                        messages: messages, model: model, tools: tools, options: options)
                    let requestData = try JSONEncoder().encode(body)

                    var urlRequest = URLRequest(url: streamURL(model: model))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("CopilotChat/1.0", forHTTPHeaderField: "User-Agent")
                    urlRequest.httpBody = requestData

                    let bytes = try await SSEParser.validatedBytes(
                        for: urlRequest, session: SSEParser.urlSession)
                    let stream = parseGeminiSSE(bytes: bytes)

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
        let body = buildRequest(messages: messages, model: model, tools: tools, options: options)
        let requestData = try JSONEncoder().encode(body)

        var urlRequest = URLRequest(url: generateURL(model: model))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("CopilotChat/1.0", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = requestData

        let (data, response) = try await SSEParser.urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.invalidResponse(statusCode: code, body: body)
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return decoded.toProviderResponse()
    }

    // MARK: - Request Building

    private func buildRequest(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> GeminiRequest {
        let (systemInstruction, contents) = convertMessages(messages)
        let geminiTools = tools.map { convertTools($0) }
        let thinkingConfig = ProviderTransform.geminiThinkingConfig(
            modelId: model, effort: options.reasoningEffort)

        return GeminiRequest(
            contents: contents,
            systemInstruction: (options.systemPrompt ?? systemInstruction).map {
                GeminiContent(role: nil, parts: [.init(text: $0)])
            },
            generationConfig: GeminiGenerationConfig(
                maxOutputTokens: options.maxOutputTokens ?? 8192,
                temperature: options.temperature ?? 0.7,
                topP: options.topP,
                topK: options.topK
            ),
            tools: geminiTools,
            thinkingConfig: thinkingConfig
        )
    }

    // MARK: - Message Conversion

    private func convertMessages(_ messages: [APIMessage]) -> (String?, [GeminiContent]) {
        var systemPrompt: String?
        var contents: [GeminiContent] = []

        for msg in messages {
            switch msg.role {
            case "system":
                systemPrompt = msg.content
            case "user":
                contents.append(GeminiContent(
                    role: "user",
                    parts: [.init(text: msg.content ?? "")]))
            case "assistant":
                var parts: [GeminiPart] = []
                if let content = msg.content, !content.isEmpty {
                    parts.append(.init(text: content))
                }
                if let toolCalls = msg.toolCalls {
                    for call in toolCalls {
                        let args = parseJSONToDict(call.function.arguments)
                        parts.append(.init(functionCall: GeminiFunctionCall(
                            name: call.function.name, args: args)))
                    }
                }
                if !parts.isEmpty {
                    contents.append(GeminiContent(role: "model", parts: parts))
                }
            case "tool":
                if let content = msg.content {
                    let response: [String: AnyCodable]
                    if let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] {
                        response = parsed.mapValues { AnyCodable($0) }
                    } else {
                        response = ["result": AnyCodable(content)]
                    }
                    // Look up tool name from preceding assistant message's tool calls
                    let toolName = messages.lazy
                        .filter { $0.role == "assistant" }
                        .flatMap { $0.toolCalls ?? [] }
                        .first { $0.id == msg.toolCallId }?.function.name ?? "tool"
                    contents.append(GeminiContent(
                        role: "user",
                        parts: [.init(functionResponse: GeminiFunctionResponse(
                            name: toolName, response: response))]))
                }
            default:
                break
            }
        }

        return (systemPrompt, contents)
    }

    private func convertTools(_ tools: [APITool]) -> [GeminiToolDeclaration] {
        let declarations = tools.map { tool -> GeminiFunctionDeclaration in
            let params: AnyCodable
            if let p = tool.function.parameters {
                params = AnyCodable(p.mapValues { $0.value })
            } else {
                params = AnyCodable(["type": "object", "properties": [String: Any]()])
            }
            return GeminiFunctionDeclaration(
                name: tool.function.name,
                description: tool.function.description,
                parameters: params)
        }
        return [GeminiToolDeclaration(functionDeclarations: declarations)]
    }

    private func parseJSONToDict(_ json: String) -> [String: AnyCodable] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj.mapValues { AnyCodable($0) }
    }

    // MARK: - Gemini SSE Parsing (alt=sse mode)

    private func parseGeminiSSE(
        bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let decoder = JSONDecoder()
                    var toolCallIndex = 0

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8) else { continue }

                        guard let response = try? decoder.decode(GeminiResponse.self, from: data) else { continue }

                        if let candidate = response.candidates?.first,
                           let parts = candidate.content?.parts {
                            for part in parts {
                                if let text = part.text, !text.isEmpty {
                                    if part.thought == true {
                                        continuation.yield(.thinkingDelta(text))
                                    } else {
                                        continuation.yield(.contentDelta(text))
                                    }
                                }
                                if let fc = part.functionCall {
                                    let args = try? JSONEncoder().encode(fc.args)
                                    let argsStr = args.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                    continuation.yield(.toolCallStart(
                                        index: toolCallIndex,
                                        id: "call_\(UUID().uuidString.prefix(8))",
                                        name: fc.name))
                                    continuation.yield(.toolCallDelta(
                                        index: toolCallIndex, arguments: argsStr))
                                    continuation.yield(.toolCallStop(index: toolCallIndex))
                                    toolCallIndex += 1
                                }
                            }
                        }

                        if let usage = response.usageMetadata {
                            continuation.yield(.usage(TokenUsage(
                                promptTokens: usage.promptTokenCount ?? 0,
                                completionTokens: usage.candidatesTokenCount ?? 0,
                                totalTokens: (usage.promptTokenCount ?? 0) + (usage.candidatesTokenCount ?? 0))))
                        }

                        if let candidate = response.candidates?.first,
                           let finishReason = candidate.finishReason {
                            let reason: ChatMessage.FinishReason
                            switch finishReason {
                            case "STOP": reason = .stop
                            case "MAX_TOKENS": reason = .length
                            default: reason = toolCallIndex > 0 ? .toolCalls : .stop
                            }
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
}

// MARK: - Gemini API Types

private struct GeminiRequest: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiContent?
    let generationConfig: GeminiGenerationConfig
    let tools: [GeminiToolDeclaration]?
    let thinkingConfig: [String: AnyCodable]?
}

private struct GeminiContent: Codable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiPart: Codable {
    var text: String?
    var thought: Bool?
    var functionCall: GeminiFunctionCall?
    var functionResponse: GeminiFunctionResponse?
}

private struct GeminiFunctionCall: Codable {
    let name: String
    let args: [String: AnyCodable]
}

private struct GeminiFunctionResponse: Codable {
    let name: String
    let response: [String: AnyCodable]
}

private struct GeminiGenerationConfig: Encodable {
    let maxOutputTokens: Int
    let temperature: Double
    let topP: Double?
    let topK: Int?
}

private struct GeminiToolDeclaration: Encodable {
    let functionDeclarations: [GeminiFunctionDeclaration]
}

private struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String?
    let parameters: AnyCodable
}

private struct GeminiResponse: Codable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsage?
    let error: GeminiAPIError?

    func toProviderResponse() -> ProviderResponse {
        var text = ""
        var toolCalls: [ToolCall] = []

        if let candidate = candidates?.first, let parts = candidate.content?.parts {
            for part in parts {
                if let t = part.text { text += t }
                if let fc = part.functionCall {
                    let args = (try? JSONEncoder().encode(fc.args))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append(ToolCall(
                        id: "call_\(UUID().uuidString.prefix(8))",
                        function: .init(name: fc.name, arguments: args)))
                }
            }
        }

        let usage = usageMetadata.map {
            TokenUsage(
                promptTokens: $0.promptTokenCount ?? 0,
                completionTokens: $0.candidatesTokenCount ?? 0,
                totalTokens: ($0.promptTokenCount ?? 0) + ($0.candidatesTokenCount ?? 0))
        }

        let finishReason: ChatMessage.FinishReason? = {
            if !toolCalls.isEmpty { return .toolCalls }
            guard let reason = candidates?.first?.finishReason else { return nil }
            switch reason {
            case "STOP": return .stop
            case "MAX_TOKENS": return .length
            default: return .stop
            }
        }()

        return ProviderResponse(content: text.isEmpty ? nil : text,
                                toolCalls: toolCalls, usage: usage, finishReason: finishReason)
    }
}

private struct GeminiCandidate: Codable {
    let content: GeminiContent?
    let finishReason: String?
}

private struct GeminiUsage: Codable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let cachedContentTokenCount: Int?
}

private struct GeminiAPIError: Codable {
    let message: String?
    let status: String?
}
