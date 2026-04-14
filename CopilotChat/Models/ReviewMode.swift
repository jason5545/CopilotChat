#if REVIEW
import Foundation

enum ReviewMode {
    private static let enabledKey = "reviewModeEnabled"
    private static let passwordKey = "reviewModeEnteredPassword"

    static let demoUsername = "copilotchat-demo"
    static let demoAvatarUrl = "https://avatars.githubusercontent.com/u/9919?v=4"
    static let demoToken = "review-demo-token"
    static let defaultProviderId = "github-copilot"
    static let defaultModelId = "claude-sonnet-4"
    static let password = "copilotchat-review-2026lisa0624"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var enteredPassword: String {
        get { UserDefaults.standard.string(forKey: passwordKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: passwordKey) }
    }

    @discardableResult
    static func unlock(using candidate: String) -> Bool {
        let normalizedCandidate = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        enteredPassword = normalizedCandidate
        let unlocked = normalizedCandidate == password
        UserDefaults.standard.set(unlocked, forKey: enabledKey)
        return unlocked
    }

    static func lock() {
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    static var lockedDescription: String {
        "Locked review builds behave like the normal GitHub sign-in flow until unlocked."
    }

    static var unlockedDescription: String {
        "Demo mode is unlocked for App Review."
    }

    @MainActor
    static func configureDefaults(_ settingsStore: SettingsStore) {
        if isEnabled {
            settingsStore.selectedModel = defaultModelId
        }
    }

    @MainActor
    static func configureDefaults(_ registry: ProviderRegistry, settingsStore: SettingsStore) {
        guard isEnabled else { return }
        registry.activeProviderId = defaultProviderId
        registry.activeModelId = defaultModelId
        settingsStore.selectedModel = defaultModelId
    }

    static func makeSampleConversations() -> [Conversation] {
        let now = Date()

        let conv1 = Conversation(
            title: "Explain async/await in Swift",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "Can you explain how async/await works in Swift and when I should use it over completion handlers?",
                    timestamp: now.addingTimeInterval(-3600)
                ),
                ChatMessage(
                    role: .assistant,
                    content: """
                    **Async/Await in Swift**

                    Async/await is Swift's structured concurrency model introduced in Swift 5.5. It provides a cleaner way to write asynchronous code compared to completion handlers.

                    **Key Concepts:**

                    1. **`async`** marks a function as asynchronous
                    2. **`await`** suspends execution until the async operation completes
                    3. **`Task`** creates a new concurrency context

                    **When to use async/await over completion handlers:**

                    - Better readability with linear control flow
                    - Natural `try` / `catch` error handling
                    - Easier debugging and maintenance

                    ```swift
                    func fetchUser(id: String) async throws -> User
                    ```

                    Use completion handlers mainly when you must bridge older callback-based APIs.
                    """,
                    timestamp: now.addingTimeInterval(-3570),
                    tokenUsage: TokenUsage(promptTokens: 42, completionTokens: 186, totalTokens: 228)
                ),
            ],
            providerId: defaultProviderId,
            modelId: "gpt-4o",
            createdAt: now.addingTimeInterval(-3600),
            updatedAt: now.addingTimeInterval(-3570)
        )

        let conv2 = Conversation(
            title: "Build a SwiftUI list with search",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "How do I add a search bar to a SwiftUI List?",
                    timestamp: now.addingTimeInterval(-7200)
                ),
                ChatMessage(
                    role: .assistant,
                    content: """
                    You can use `.searchable()` in SwiftUI:

                    ```swift
                    struct ContentView: View {
                        @State private var searchText = ""
                        let items = ["Apple", "Banana", "Cherry"]

                        var filteredItems: [String] {
                            if searchText.isEmpty { items }
                            else { items.filter { $0.localizedCaseInsensitiveContains(searchText) } }
                        }

                        var body: some View {
                            NavigationStack {
                                List(filteredItems, id: \\.self) { item in
                                    Text(item)
                                }
                                .searchable(text: $searchText, prompt: "Search fruits")
                            }
                        }
                    }
                    ```

                    The search field appears automatically in the navigation bar on iOS.
                    """,
                    timestamp: now.addingTimeInterval(-7180),
                    tokenUsage: TokenUsage(promptTokens: 28, completionTokens: 142, totalTokens: 170)
                ),
            ],
            providerId: defaultProviderId,
            modelId: defaultModelId,
            createdAt: now.addingTimeInterval(-7200),
            updatedAt: now.addingTimeInterval(-7180)
        )

        let conv3 = Conversation(
            title: "Copilot subscription features",
            messages: [
                ChatMessage(
                    role: .user,
                    content: "What models are available with my Copilot subscription?",
                    timestamp: now.addingTimeInterval(-600)
                ),
                ChatMessage(
                    role: .assistant,
                    content: """
                    With an active GitHub Copilot subscription in Copilot Chat, you can browse and switch between models such as:

                    - **Claude Sonnet 4** for balanced coding and chat
                    - **GPT-4o** for general assistance and multimodal tasks
                    - **Gemini 2.5 Pro** for reasoning-heavy prompts
                    - **o3-mini** for compact reasoning workflows

                    The app keeps the selected Copilot provider visible in Settings and lets you switch models from the model picker at any time.
                    """,
                    timestamp: now.addingTimeInterval(-580),
                    tokenUsage: TokenUsage(promptTokens: 22, completionTokens: 98, totalTokens: 120)
                ),
            ],
            providerId: defaultProviderId,
            modelId: "gemini-2.5-pro",
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-580)
        )

        return [conv3, conv1, conv2]
    }

    static func response(for prompt: String, model: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = trimmed.isEmpty ? "your request" : trimmed

        return """
        Review mode response from \(model).

        This build includes a demonstration mode for App Review, so the app opens with a populated Copilot session and does not require a personal GitHub account.

        You asked: \(headline)

        What this demonstrates:
        - authenticated Copilot account state
        - existing conversation history with sample content
        - model selection and provider configuration
        - message sending, response rendering, and token usage UI
        """
    }

    static func title(for userMessage: String) -> String {
        let text = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Review conversation" }
        return text.count > 50 ? String(text.prefix(50)) + "..." : text
    }
}

extension ReviewMode {
    static let copilotProvider = ModelsDevProvider(
        id: defaultProviderId,
        name: "GitHub Copilot",
        env: [],
        npm: "@ai-sdk/openai-compatible",
        api: "https://api.githubcopilot.com",
        doc: "https://github.com/features/copilot",
        models: [
            "claude-sonnet-4": ModelsDevModel(
                id: "claude-sonnet-4",
                name: "Claude Sonnet 4",
                reasoning: true,
                attachment: true,
                toolCall: true,
                structuredOutput: false,
                temperature: true,
                cost: nil,
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil,
                status: nil,
                family: "Claude",
                knowledge: nil,
                modalities: ModelsDevModalities(input: ["text", "image"], output: ["text"]),
                openWeights: nil,
                lastUpdated: nil,
                isSubscriptonPlan: true
            ),
            "gpt-4o": ModelsDevModel(
                id: "gpt-4o",
                name: "GPT-4o",
                reasoning: true,
                attachment: true,
                toolCall: true,
                structuredOutput: false,
                temperature: true,
                cost: nil,
                limit: ModelsDevLimit(context: 128_000, output: 16_384, input: nil),
                releaseDate: nil,
                status: nil,
                family: "GPT",
                knowledge: nil,
                modalities: ModelsDevModalities(input: ["text", "image"], output: ["text"]),
                openWeights: nil,
                lastUpdated: nil,
                isSubscriptonPlan: true
            ),
            "gemini-2.5-pro": ModelsDevModel(
                id: "gemini-2.5-pro",
                name: "Gemini 2.5 Pro",
                reasoning: true,
                attachment: true,
                toolCall: true,
                structuredOutput: false,
                temperature: true,
                cost: nil,
                limit: ModelsDevLimit(context: 1_000_000, output: 32_768, input: nil),
                releaseDate: nil,
                status: nil,
                family: "Gemini",
                knowledge: nil,
                modalities: ModelsDevModalities(input: ["text", "image"], output: ["text"]),
                openWeights: nil,
                lastUpdated: nil,
                isSubscriptonPlan: true
            ),
            "o3-mini": ModelsDevModel(
                id: "o3-mini",
                name: "o3-mini",
                reasoning: true,
                attachment: false,
                toolCall: true,
                structuredOutput: false,
                temperature: false,
                cost: nil,
                limit: ModelsDevLimit(context: 200_000, output: 100_000, input: nil),
                releaseDate: nil,
                status: nil,
                family: "OpenAI",
                knowledge: nil,
                modalities: ModelsDevModalities(input: ["text"], output: ["text"]),
                openWeights: nil,
                lastUpdated: nil,
                isSubscriptonPlan: true
            ),
        ]
    )
}

struct ReviewCopilotProvider: LLMProvider {
    let id = ReviewMode.defaultProviderId
    let displayName = "GitHub Copilot"

    func streamCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        let prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
        let response = ReviewMode.response(for: prompt, model: model)

        return AsyncThrowingStream { continuation in
            continuation.yield(.thinkingDelta("Review mode demonstration"))
            continuation.yield(.contentDelta(response))
            continuation.yield(.usage(TokenUsage(promptTokens: max(24, prompt.count / 4), completionTokens: max(80, response.count / 5), totalTokens: max(104, prompt.count / 4 + response.count / 5))))
            continuation.yield(.finish(reason: .stop))
            continuation.finish()
        }
    }

    func sendCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) async throws -> ProviderResponse {
        let prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
        let title = ReviewMode.title(for: prompt)
        return ProviderResponse(
            content: title,
            usage: TokenUsage(promptTokens: max(12, prompt.count / 4), completionTokens: max(6, title.count / 4), totalTokens: max(18, prompt.count / 4 + title.count / 4)),
            finishReason: .stop
        )
    }
}
#endif
