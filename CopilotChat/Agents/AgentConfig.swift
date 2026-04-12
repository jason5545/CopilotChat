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

// MARK: - Subagent Configuration

enum SubagentMode: String, Sendable {
    case primary  = "primary"
    case subagent = "subagent"
}

enum ToolPermissionAction: String, Sendable {
    case allow
    case deny
    case ask
}

struct ToolPermissionRule: Sendable, Hashable {
    let toolName: String
    let pattern: String
    let action: ToolPermissionAction

    init(_ toolName: String, pattern: String = "*", action: ToolPermissionAction) {
        self.toolName = toolName
        self.pattern = pattern
        self.action = action
    }

    static func defaultRules(denyAll: Bool = false) -> [ToolPermissionRule] {
        var rules: [ToolPermissionRule] = [
            .init("tool_search", action: .allow),
            .init("todowrite", action: denyAll ? .deny : .allow),
            .init("task", action: denyAll ? .deny : .allow),
        ]
        if denyAll {
            rules.append(.init("*", action: .deny))
        }
        return rules
    }
}

struct SubagentDefinition: Sendable {
    let name: String
    let mode: SubagentMode
    let description: String
    let systemPrompt: String
    let permissionRules: [ToolPermissionRule]
    let maxIterations: Int
    let maxOutputTokens: Int?
    let temperature: Double?
    let model: String?
    let thoroughness: SubagentThoroughness?

    struct SubagentThoroughness: Sendable {
        let label: String
        let description: String
    }
}

enum SubagentRegistry: Sendable {

    static let explore = SubagentDefinition(
        name: "explore",
        mode: .subagent,
        description: "Fast agent specialized for exploring codebases. Use this agent when you need to quickly find files by patterns (e.g. \"src/**/*.tsx\"), search code for keywords (e.g. \"API endpoints\"), or answer questions about the codebase (e.g. \"how do API endpoints work?\"). When calling this agent, specify the desired thoroughness level: quick for basic searches, medium for moderate exploration, or very thorough for comprehensive analysis across multiple locations and naming conventions.",
        systemPrompt: """
            You are a fast codebase exploration agent. Your job is to search and read files to answer questions about the codebase. You have access to read-only tools: list_files, read_file, grep_files, tool_search, switch_mode, and web search.

            IMPORTANT RULES:
            - NEVER edit, write, create, delete, or move any files
            - NEVER execute shell commands or scripts
            - Only use tools to READ and SEARCH the codebase
            - Be thorough but efficient — read files in parallel when possible
            - Return your findings as a concise, well-organized summary
            - Include specific file paths and line numbers when referencing code
            - If you cannot find the answer, say so clearly rather than guessing
            """,
        permissionRules: [
            .init("list_files", action: .allow),
            .init("read_file", action: .allow),
            .init("grep_files", action: .allow),
            .init("tool_search", action: .allow),
            .init("switch_mode", action: .allow),
            .init("brave_web_search", action: .allow),
            .init("write_file", action: .deny),
            .init("edit_file", action: .deny),
            .init("create_file", action: .deny),
            .init("delete_file", action: .deny),
            .init("move_file", action: .deny),
            .init("curl_request", action: .deny),
            .init("wget_download", action: .deny),
            .init("web_screenshot", action: .deny),
            .init("todowrite", action: .deny),
            .init("task", action: .deny),
            .init("*", action: .deny),
        ],
        maxIterations: 10,
        maxOutputTokens: nil,
        temperature: nil,
        model: nil,
        thoroughness: .init(label: "thoroughness", description: "Desired thoroughness level for exploration: quick, medium, very thorough")
    )

    static let general = SubagentDefinition(
        name: "general",
        mode: .subagent,
        description: "General-purpose agent for researching complex questions and executing multi-step tasks that require combining multiple tools. Use this agent when you need to perform multiple related searches, fetch web content, and synthesize information from various sources.",
        systemPrompt: """
            You are a general-purpose research agent. You can search the codebase, fetch web content, and use available tools to answer questions comprehensively. Focus on being thorough and returning well-organized results. Include specific references (file paths, URLs) in your findings.
            """,
        permissionRules: [
            .init("todowrite", action: .deny),
            .init("task", action: .deny),
            .init("write_file", action: .deny),
            .init("edit_file", action: .deny),
            .init("create_file", action: .deny),
            .init("delete_file", action: .deny),
            .init("move_file", action: .deny),
        ],
        maxIterations: 15,
        maxOutputTokens: nil,
        temperature: nil,
        model: nil,
        thoroughness: nil
    )

    private static let all: [SubagentDefinition] = [explore, general]

    static func resolve(_ name: String) -> SubagentDefinition? {
        all.first { $0.name == name }
    }

    static func availableTypes() -> [SubagentDefinition] {
        all.filter { $0.mode == .subagent }
    }
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
            temperature: AgentConfig.title.temperature,
            agentInitiated: true
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
