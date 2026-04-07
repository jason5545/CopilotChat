import Foundation

// MARK: - Chat Message

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var content: String
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolName: String?
    let timestamp: Date

    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.timestamp = timestamp
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }
}

struct ToolCall: Identifiable, Equatable, Codable {
    let id: String
    let function: FunctionCall

    struct FunctionCall: Equatable, Codable {
        let name: String
        let arguments: String
    }
}

// MARK: - Tool Call Status

enum ToolCallStatus: Equatable {
    case awaitingPermission
    case pending
    case executing
    case completed
    case failed(String)
}

enum PermissionDecision: Sendable {
    case allowOnce
    case allowForChat
    case allowAlways
    case deny
}

enum ToolPermissionOverride: String, Codable, Sendable {
    case alwaysAllow
    case alwaysDeny
}

// MARK: - API Request Types

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [APIMessage]
    let stream: Bool
    let maxTokens: Int?
    let temperature: Double?
    let tools: [APITool]?
    let toolChoice: String?
    let streamOptions: StreamOptions?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, tools
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case streamOptions = "stream_options"
    }

    struct StreamOptions: Encodable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }
}

struct APIMessage: Encodable {
    let role: String
    let content: String?
    let toolCalls: [APIToolCall]?
    let toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    init(role: String, content: String?, toolCalls: [APIToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        // Always encode content (as null when nil) — the API requires "content": null
        // on assistant messages with tool_calls; omitting the key causes hangs.
        try container.encode(content, forKey: .content)
        // Only include tool_calls / tool_call_id when they carry a value
        if let toolCalls {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
        if let toolCallId {
            try container.encode(toolCallId, forKey: .toolCallId)
        }
    }
}

struct APIToolCall: Encodable {
    let id: String
    let type: String
    let function: APIFunctionCall

    struct APIFunctionCall: Encodable {
        let name: String
        let arguments: String
    }
}

struct APITool: Encodable {
    let type: String
    let function: APIToolFunction

    struct APIToolFunction: Encodable {
        let name: String
        let description: String
        let parameters: [String: AnyCodable]?

        enum CodingKeys: String, CodingKey {
            case name, description, parameters
        }
    }
}

// MARK: - Token Usage

struct TokenUsage: Codable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

}

// MARK: - API Response Types (Streaming)

struct StreamChunk: Decodable {
    let id: String?
    let choices: [StreamChoice]?
    let usage: TokenUsage?

    struct StreamChoice: Decodable {
        let index: Int
        let delta: StreamDelta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct StreamDelta: Decodable {
        let role: String?
        let content: String?
        let toolCalls: [StreamToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }

    struct StreamToolCall: Decodable {
        let index: Int
        let id: String?
        let type: String?
        let function: StreamFunction?

        struct StreamFunction: Decodable {
            let name: String?
            let arguments: String?
        }
    }
}

// MARK: - Models List Response

struct ModelsResponse: Decodable {
    let data: [ModelInfo]

    struct ModelInfo: Decodable, Identifiable {
        let id: String
        let name: String?
        let version: String?
        let capabilities: Capabilities?

        var displayName: String {
            name ?? id
        }

        /// Raw context window from the API payload.
        var contextWindowTokens: Int? {
            capabilities?.limits?.maxContextWindowTokens
                ?? capabilities?.limits?.maxPromptTokens
        }

        /// Display-friendly context size aligned with VS Code's model metadata.
        var displayContextWindowTokens: Int? {
            if let prompt = capabilities?.limits?.maxPromptTokens,
               let output = capabilities?.limits?.maxOutputTokens {
                return prompt + output
            }
            return contextWindowTokens
        }

        /// Prompt limit for compaction logic and ContextRing.
        var maxPromptTokens: Int? {
            capabilities?.limits?.maxPromptTokens
        }

        struct Capabilities: Decodable {
            let limits: Limits?

            struct Limits: Decodable {
                let maxContextWindowTokens: Int?
                let maxPromptTokens: Int?
                let maxOutputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case maxContextWindowTokens = "max_context_window_tokens"
                    case maxPromptTokens = "max_prompt_tokens"
                    case maxOutputTokens = "max_output_tokens"
                }
            }
        }
    }
}

// MARK: - Non-Streaming Response (for compaction)

struct NonStreamingResponse: Decodable {
    let choices: [Choice]
    let usage: TokenUsage?

    struct Choice: Decodable {
        let message: Message

        struct Message: Decodable {
            let role: String
            let content: String?
        }
    }
}

// MARK: - Device Flow Types

struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

struct OAuthTokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
    }
}

struct GitHubUser: Decodable {
    let login: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarUrl = "avatar_url"
    }
}

// MARK: - MCP Types

struct MCPServerConfig: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var url: String
    var headers: [String: String]
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, url: String, headers: [String: String] = [:], isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.headers = headers
        self.isEnabled = isEnabled
    }
}

struct MCPTool: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]?
    let serverName: String
}

// MARK: - AnyCodable helper

struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

// MARK: - Responses API Types

struct ResponsesAPIRequest: Encodable {
    let model: String
    let instructions: String?
    let input: [ResponsesInputItem]
    let stream: Bool
    let maxOutputTokens: Int?
    let temperature: Double?
    let tools: [ResponsesAPITool]?
    let toolChoice: String?

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, stream, temperature, tools
        case maxOutputTokens = "max_output_tokens"
        case toolChoice = "tool_choice"
    }
}

enum ResponsesInputItem: Encodable {
    case userMessage(content: String)
    case assistantMessage(content: String)
    case functionCall(callId: String, name: String, arguments: String)
    case functionCallOutput(callId: String, output: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        switch self {
        case .userMessage(let content):
            try container.encode("user", forKey: .init("role"))
            try container.encode(content, forKey: .init("content"))
        case .assistantMessage(let content):
            try container.encode("message", forKey: .init("type"))
            try container.encode("assistant", forKey: .init("role"))
            let parts: [[String: String]] = [["type": "output_text", "text": content]]
            try container.encode(parts, forKey: .init("content"))
        case .functionCall(let callId, let name, let arguments):
            try container.encode("function_call", forKey: .init("type"))
            try container.encode(callId, forKey: .init("call_id"))
            try container.encode(name, forKey: .init("name"))
            try container.encode(arguments, forKey: .init("arguments"))
        case .functionCallOutput(let callId, let output):
            try container.encode("function_call_output", forKey: .init("type"))
            try container.encode(callId, forKey: .init("call_id"))
            try container.encode(output, forKey: .init("output"))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct ResponsesAPITool: Encodable {
    let type: String
    let name: String
    let description: String
    let parameters: [String: AnyCodable]?
}

// MARK: - Responses API SSE Payloads

struct ResponsesStreamEvent: Decodable {
    let delta: String?
    let outputIndex: Int?
    let item: ResponsesStreamItem?
    let name: String?
    let arguments: String?
    let response: ResponsesResponsePayload?

    enum CodingKeys: String, CodingKey {
        case delta
        case outputIndex = "output_index"
        case item, name, arguments, response
    }
}

struct ResponsesStreamItem: Decodable {
    let type: String?
    let callId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case name
    }
}

struct ResponsesResponsePayload: Decodable {
    let usage: ResponsesUsage?
}

struct ResponsesUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }

    var asTokenUsage: TokenUsage {
        TokenUsage(promptTokens: inputTokens, completionTokens: outputTokens,
                   totalTokens: inputTokens + outputTokens)
    }
}

// MARK: - Responses API Non-Streaming Response

struct NonStreamingResponsesResponse: Decodable {
    let output: [ResponsesOutputItem]
    let usage: ResponsesUsage?

    struct ResponsesOutputItem: Decodable {
        let type: String
        let content: [ResponsesContentPart]?
    }

    struct ResponsesContentPart: Decodable {
        let type: String
        let text: String?
    }
}
