import Foundation

// MARK: - Provider Protocol

protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func streamCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> AsyncThrowingStream<ProviderEvent, Error>

    func sendCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) async throws -> ProviderResponse
}

// MARK: - Provider Events (unified streaming events)

enum ProviderEvent: Sendable {
    case contentDelta(String)
    case thinkingDelta(String)
    case toolCallStart(index: Int, id: String, name: String)
    case toolCallDelta(index: Int, arguments: String)
    case toolCallStop(index: Int)
    case usage(TokenUsage)
    case finish(reason: ChatMessage.FinishReason)
    case error(Error)
}

// MARK: - Provider Options

struct ProviderOptions: Sendable {
    var maxOutputTokens: Int?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var reasoningEffort: String?
    var systemPrompt: String?
    var toolChoice: String?
    /// Provider-specific extra fields for the request body (e.g., thinking, enable_thinking)
    var extraFields: [String: AnyCodable]?

    init(
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        reasoningEffort: String? = nil,
        systemPrompt: String? = nil,
        toolChoice: String? = nil,
        extraFields: [String: AnyCodable]? = nil
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.reasoningEffort = reasoningEffort
        self.systemPrompt = systemPrompt
        self.toolChoice = toolChoice
        self.extraFields = extraFields
    }
}

// MARK: - Provider Response (non-streaming)

struct ProviderResponse: Sendable {
    let content: String?
    let toolCalls: [ToolCall]
    let usage: TokenUsage?
    let finishReason: ChatMessage.FinishReason?

    init(
        content: String? = nil,
        toolCalls: [ToolCall] = [],
        usage: TokenUsage? = nil,
        finishReason: ChatMessage.FinishReason? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
    }
}

// MARK: - Provider Type (routing key based on models.dev npm field)

enum ProviderAPIFormat: String, Sendable {
    case openaiCompatible    // @ai-sdk/openai, @ai-sdk/openai-compatible, @ai-sdk/xai, @ai-sdk/groq, etc.
    case anthropicCompatible // @ai-sdk/anthropic
    case gemini              // @ai-sdk/google
    case copilot             // GitHub Copilot (special auth)
    case openaiCodex         // OpenAI Codex (OAuth)

    static func from(npm: String?) -> ProviderAPIFormat {
        guard let npm else { return .openaiCompatible }
        if npm.contains("anthropic") { return .anthropicCompatible }
        if npm.contains("google") { return .gemini }
        return .openaiCompatible
    }
}

// MARK: - Provider Error

enum ProviderError: LocalizedError {
    case invalidResponse(statusCode: Int, body: String)
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case streamingFailed(String)
    case unsupportedModel(String)
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let code, let body):
            return "API error (\(code)): \(body.prefix(200))"
        case .authenticationFailed:
            return "Authentication failed"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds))s"
            }
            return "Rate limited"
        case .streamingFailed(let msg):
            return "Streaming failed: \(msg)"
        case .unsupportedModel(let model):
            return "Unsupported model: \(model)"
        case .noAPIKey:
            return "API key not configured"
        }
    }
}
