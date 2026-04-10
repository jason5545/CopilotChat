import Foundation

// MARK: - OpenAI-Format SSE Parser

/// Shared SSE parser for OpenAI Chat Completions format.
/// Used by CopilotProvider, OpenAICompatibleProvider, and any provider
/// that speaks the OpenAI streaming protocol.
enum SSEParser {

    /// Parse an OpenAI Chat Completions SSE byte stream into ProviderEvents.
    static func parseChatCompletionsStream(
        bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
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

                        // reasoning_content (DeepSeek, Z.AI) or reasoning_text (Copilot Claude)
                        if let reasoning = choice.delta.reasoningContent ?? choice.delta.reasoningText {
                            continuation.yield(.thinkingDelta(reasoning))
                        }

                        if let toolCallDeltas = choice.delta.toolCalls {
                            for delta in toolCallDeltas {
                                if let id = delta.id {
                                    continuation.yield(.toolCallStart(
                                        index: delta.index, id: id, name: delta.function?.name ?? ""))
                                }
                                if let args = delta.function?.arguments {
                                    continuation.yield(.toolCallDelta(index: delta.index, arguments: args))
                                }
                            }
                        }

                        if let finishReason = choice.finishReason {
                            finishedReason = finishReason
                        }
                    }

                    if let reason = finishedReason {
                        let mapped = mapFinishReason(reason)
                        continuation.yield(.finish(reason: mapped))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parse an OpenAI Responses API SSE stream into ProviderEvents.
    static func parseResponsesStream(
        bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
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

                        case "response.reasoning_text.delta",
                             "response.reasoning_summary_text.delta":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data),
                               let delta = evt.delta {
                                continuation.yield(.thinkingDelta(delta))
                            }

                        case "response.output_item.added":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data),
                               let item = evt.item, item.type == "function_call" {
                                let idx = evt.outputIndex ?? 0
                                hasToolCalls = true
                                continuation.yield(.toolCallStart(
                                    index: idx, id: item.callId ?? "", name: item.name ?? ""))
                            }

                        case "response.function_call_arguments.delta":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data) {
                                let idx = evt.outputIndex ?? 0
                                if let args = evt.delta {
                                    continuation.yield(.toolCallDelta(index: idx, arguments: args))
                                }
                            }

                        case "response.completed":
                            if let evt = try? decoder.decode(ResponsesStreamEvent.self, from: data),
                               let usage = evt.response?.usage {
                                continuation.yield(.usage(usage.asTokenUsage))
                            }
                            let reason: ChatMessage.FinishReason = hasToolCalls ? .toolCalls : .stop
                            continuation.yield(.finish(reason: reason))

                        case "response.failed":
                            continuation.yield(.finish(reason: .error))

                        case "response.incomplete":
                            continuation.yield(.finish(reason: .length))

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

    // MARK: - Helpers

    /// Open a validated byte stream — checks HTTP 200 status.
    static func validatedBytes(
        for request: URLRequest,
        session: URLSession = .shared
    ) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse(statusCode: 0, body: "No HTTP response")
        }
        if http.statusCode == 401 {
            throw ProviderError.authenticationFailed
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        }
        if http.statusCode == 529 || http.statusCode == 503 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw ProviderError.overloaded(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
            throw ProviderError.invalidResponse(statusCode: http.statusCode, body: body)
        }
        return bytes
    }

    /// Build a standard POST request with JSON body and auth header.
    static func buildRequest(
        url: URL,
        apiKey: String,
        body: Data,
        authHeader: String = "Authorization",
        authPrefix: String = "Bearer ",
        extraHeaders: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("\(authPrefix)\(apiKey)", forHTTPHeaderField: authHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CopilotChat/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private static func mapFinishReason(_ reason: String) -> ChatMessage.FinishReason {
        switch reason {
        case "stop", "end_turn": return .stop
        case "length", "max_tokens": return .length
        case "tool_calls", "tool_use": return .toolCalls
        default: return .stop
        }
    }

    // MARK: - Shared Message Conversion

    /// Convert APIMessages to Responses API input format.
    /// Shared by CopilotProvider and OpenAICodexProvider.
    static func convertToResponsesInput(messages: [APIMessage]) -> [ResponsesInputItem] {
        var input: [ResponsesInputItem] = []
        for msg in messages {
            switch msg.role {
            case "system":
                continue
            case "user":
                input.append(.userMessage(content: msg.content ?? ""))
            case "assistant":
                if let content = msg.content, !content.isEmpty {
                    input.append(.assistantMessage(content: content))
                }
                if let toolCalls = msg.toolCalls {
                    for call in toolCalls {
                        input.append(.functionCall(
                            callId: call.id, name: call.function.name,
                            arguments: call.function.arguments))
                    }
                }
            case "tool":
                if let callId = msg.toolCallId {
                    input.append(.functionCallOutput(callId: callId, output: msg.content ?? ""))
                }
            default:
                break
            }
        }
        return input
    }

    /// Check if a model should use the Responses API (GPT/O-series).
    static func useResponsesAPI(model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    /// Validate a non-streaming HTTP response, throwing on error.
    static func validatedData(
        data: Data, response: URLResponse
    ) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse(statusCode: 0, body: "No HTTP response")
        }
        if http.statusCode == 401 { throw ProviderError.authenticationFailed }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        }
        if http.statusCode == 529 || http.statusCode == 503 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw ProviderError.overloaded(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.invalidResponse(statusCode: http.statusCode, body: body)
        }
        return data
    }
}

// MARK: - URLSession Configuration

extension SSEParser {
    static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue())
    }()
}
