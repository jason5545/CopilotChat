import Foundation
import Observation

@Observable
@MainActor
final class CopilotService {
    private static let chatEndpoint = "https://api.githubcopilot.com/chat/completions"
    private static let modelsEndpoint = "https://api.githubcopilot.com/models"
    private static let userAgent = "CopilotChat/1.0.0"

    var messages: [ChatMessage] = []
    var isStreaming = false
    var streamingError: String?
    var availableModels: [ModelsResponse.ModelInfo] = []

    private let authManager: AuthManager
    private let settingsStore: SettingsStore
    private var streamTask: Task<Void, Never>?

    init(authManager: AuthManager, settingsStore: SettingsStore) {
        self.authManager = authManager
        self.settingsStore = settingsStore
    }

    // MARK: - Chat

    func sendMessage(_ content: String, tools: [MCPTool] = []) {
        let userMessage = ChatMessage(role: .user, content: content)
        messages.append(userMessage)

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        isStreaming = true
        streamingError = nil

        streamTask = Task {
            do {
                try await streamCompletion(updatingAt: assistantIndex, tools: tools)
            } catch is CancellationError {
                // cancelled
            } catch {
                streamingError = error.localizedDescription
                if messages[assistantIndex].content.isEmpty {
                    messages[assistantIndex].content = "Error: \(error.localizedDescription)"
                }
            }
            isStreaming = false
        }
    }

    func sendToolResult(toolCallId: String, toolName: String, result: String, tools: [MCPTool] = []) {
        let toolMessage = ChatMessage(role: .tool, content: result, toolCallId: toolCallId, toolName: toolName)
        messages.append(toolMessage)

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        isStreaming = true
        streamingError = nil

        streamTask = Task {
            do {
                try await streamCompletion(updatingAt: assistantIndex, tools: tools)
            } catch is CancellationError {
                // cancelled
            } catch {
                streamingError = error.localizedDescription
            }
            isStreaming = false
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    func newConversation() {
        stopStreaming()
        messages.removeAll()
    }

    // MARK: - Streaming Implementation

    private func streamCompletion(updatingAt index: Int, tools: [MCPTool]) async throws {
        guard let token = authManager.token else {
            throw CopilotError.notAuthenticated
        }

        let apiMessages = buildAPIMessages()
        let apiTools = tools.isEmpty ? nil : tools.map { tool in
            APITool(
                type: "function",
                function: .init(
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.inputSchema
                )
            )
        }

        let request = ChatCompletionRequest(
            model: settingsStore.selectedModel,
            messages: apiMessages,
            stream: true,
            maxTokens: 8192,
            temperature: 0.7,
            tools: apiTools,
            toolChoice: apiTools != nil ? "auto" : nil
        )

        var urlRequest = URLRequest(url: URL(string: Self.chatEndpoint)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("conversation-edits", forHTTPHeaderField: "Openai-Intent")
        urlRequest.setValue("user", forHTTPHeaderField: "x-initiator")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw CopilotError.invalidResponse
        }

        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw CopilotError.httpError(http.statusCode, body)
        }

        // Parse SSE stream
        var pendingToolCalls: [String: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))

            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let choice = chunk.choices?.first else { continue }

            // Handle content delta
            if let content = choice.delta.content {
                messages[index].content += content
            }

            // Handle tool calls delta
            if let toolCallDeltas = choice.delta.toolCalls {
                for delta in toolCallDeltas {
                    let key = "\(delta.index)"
                    if let id = delta.id {
                        pendingToolCalls[key] = (id: id, name: delta.function?.name ?? "", arguments: "")
                    }
                    if let name = delta.function?.name, pendingToolCalls[key] != nil {
                        pendingToolCalls[key]?.name = name
                    }
                    if let args = delta.function?.arguments, pendingToolCalls[key] != nil {
                        pendingToolCalls[key]?.arguments += args
                    }
                }
            }

            // Handle finish
            if choice.finishReason == "tool_calls" {
                let calls = pendingToolCalls.sorted(by: { $0.key < $1.key }).map { (_, value) in
                    ToolCall(id: value.id, function: .init(name: value.name, arguments: value.arguments))
                }
                messages[index].toolCalls = calls
            }
        }
    }

    private func buildAPIMessages() -> [APIMessage] {
        var apiMessages: [APIMessage] = [
            APIMessage(role: "system", content: "You are a helpful AI assistant. Respond in the user's language.")
        ]

        for msg in messages {
            switch msg.role {
            case .system:
                continue
            case .user:
                apiMessages.append(APIMessage(role: "user", content: msg.content))
            case .assistant:
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    let apiToolCalls = toolCalls.map {
                        APIToolCall(id: $0.id, type: "function", function: .init(name: $0.function.name, arguments: $0.function.arguments))
                    }
                    apiMessages.append(APIMessage(role: "assistant", content: msg.content.isEmpty ? nil : msg.content, toolCalls: apiToolCalls))
                } else if !msg.content.isEmpty {
                    apiMessages.append(APIMessage(role: "assistant", content: msg.content))
                }
            case .tool:
                apiMessages.append(APIMessage(role: "tool", content: msg.content, toolCallId: msg.toolCallId))
            }
        }

        return apiMessages
    }

    // MARK: - Fetch Models

    func fetchModels() async {
        guard let token = authManager.token else { return }

        var request = URLRequest(url: URL(string: Self.modelsEndpoint)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            availableModels = modelsResponse.data.sorted { $0.id < $1.id }
        } catch {
            // Non-critical
        }
    }

    // MARK: - Errors

    enum CopilotError: LocalizedError {
        case notAuthenticated
        case invalidResponse
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: "Not authenticated. Please sign in to GitHub."
            case .invalidResponse: "Invalid response from server."
            case .httpError(let code, let body): "HTTP \(code): \(body)"
            }
        }
    }
}
