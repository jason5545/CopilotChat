import Foundation

// MARK: - Agent Configuration

/// Defines agent types and their configurations, inspired by OpenCode's agent system.
/// Each agent type uses a different model/settings optimized for its task.
enum AgentType: String, Sendable {
    case coder       // Main agent — user's selected model, full tools
    case title       // Title generation — lightweight model, 80 max tokens
    case summarizer  // Compaction — lightweight model, 4096 max tokens
}

struct AgentConfig: Sendable {
    let type: AgentType
    let maxOutputTokens: Int
    let systemPrompt: String
    let temperature: Double

    static let title = AgentConfig(
        type: .title,
        maxOutputTokens: 80,
        systemPrompt: "Generate a short, descriptive title (under 60 characters) for this conversation based on the user's message and the assistant's response. Output ONLY the title text, nothing else. No quotes, no prefixes.",
        temperature: 0.5
    )

    static let summarizer = AgentConfig(
        type: .summarizer,
        maxOutputTokens: 4096,
        systemPrompt: """
            You are a helpful AI assistant tasked with summarizing conversations.

            When asked to summarize, provide a detailed but concise summary of the conversation. \
            Focus on information that would be helpful for continuing the conversation, including:
            - What was done
            - What is currently being worked on
            - Which files are being modified
            - What needs to be done next

            Your summary should be comprehensive enough to provide context but concise enough to be quickly understood.
            """,
        temperature: 0.5
    )

    static let summarizerPrompt = """
        Provide a detailed but concise summary of our conversation above. \
        Focus on information that would be helpful for continuing the conversation, \
        including what we did, what we're doing, which files we're working on, \
        and what we're going to do next.
        """
}

// MARK: - Title Generator

/// Generates conversation titles using a lightweight LLM call.
/// Falls back to truncating the first user message if the LLM call fails.
@MainActor
enum TitleGenerator {

    /// Generate a title for a conversation using the given provider.
    /// Returns nil if generation fails (caller should use fallback).
    static func generate(
        userMessage: String,
        assistantPreview: String,
        provider: any LLMProvider,
        model: String
    ) async -> String? {
        let messages: [APIMessage] = [
            APIMessage(role: "system", content: AgentConfig.title.systemPrompt),
            APIMessage(role: "user", content: "User: \(userMessage.prefix(500))\nAssistant: \(assistantPreview.prefix(500))")
        ]

        let options = ProviderOptions(
            maxOutputTokens: AgentConfig.title.maxOutputTokens,
            temperature: AgentConfig.title.temperature
        )

        do {
            let response = try await provider.sendCompletion(
                messages: messages, model: model, tools: nil, options: options)
            if let title = response.content?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty, title.count < 100 {
                // Remove surrounding quotes if present
                let cleaned = title
                    .replacingOccurrences(of: "^[\"']|[\"']$", with: "", options: .regularExpression)
                return cleaned.isEmpty ? nil : cleaned
            }
        } catch {
            // Non-critical — fall back to truncation
        }
        return nil
    }

    /// Fallback: truncate first user message as title.
    static func fallbackTitle(from userMessage: String) -> String {
        let text = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 50 ? String(text.prefix(50)) + "..." : text
    }
}
