import Foundation

enum DemoMode {
    static let demoUsername = "Demo Mode"
    static let defaultProviderId = "github-copilot"
    static let defaultModelId = "claude-sonnet-4-6"

    @MainActor
    static func syncSession(
        authManager: AuthManager,
        settingsStore: SettingsStore,
        conversationStore: ConversationStore,
        copilotService: CopilotService
    ) async {
        guard let registry = copilotService.providerRegistry else { return }
        let wasUsingDemo = authManager.isDemoMode || conversationStore.isDemoSession

        if registry.hasRealConfiguredProvider {
            authManager.disableDemoMode()
            if wasUsingDemo {
                await registry.loadProviders()
            }
            if conversationStore.isDemoSession {
                await conversationStore.endDemoSession()
            }
            if let restored = conversationStore.currentConversationState() {
                restoreRealSessionSelection(
                    restored,
                    registry: registry,
                    settingsStore: settingsStore
                )
                copilotService.loadMessages(restored.messages, summaryMessageId: restored.summaryMessageId)
            } else {
                normalizeRealSessionSelection(registry: registry, settingsStore: settingsStore)
                copilotService.newConversation()
            }
            if authManager.isAuthenticated {
                await copilotService.fetchModels()
            } else {
                copilotService.availableModels = []
            }
            return
        }

        await beginSession(
            authManager: authManager,
            settingsStore: settingsStore,
            conversationStore: conversationStore,
            copilotService: copilotService
        )
    }

    @MainActor
    static func beginSession(
        authManager: AuthManager,
        settingsStore: SettingsStore,
        conversationStore: ConversationStore,
        copilotService: CopilotService
    ) async {
        authManager.enableDemoMode()
        configureDefaults(settingsStore)

        if let registry = copilotService.providerRegistry {
            registry.modelsDevProviders[defaultProviderId] = copilotProviderMetadata
            configureDefaults(registry, settingsStore: settingsStore)
        }

        conversationStore.beginDemoSession(with: makeSampleConversations())
        copilotService.newConversation()

        if let current = conversationStore.currentConversationState() {
            copilotService.loadMessages(current.messages, summaryMessageId: current.summaryMessageId)
            if let effort = current.reasoningEffort {
                settingsStore.reasoningEffort = effort
            }
            if let registry = copilotService.providerRegistry {
                registry.activeProviderId = current.providerId ?? defaultProviderId
                let modelId = current.modelId ?? defaultModelId
                registry.activeModelId = modelId
                settingsStore.selectedModel = modelId
            }
        }

        await copilotService.fetchModels()
    }

    @MainActor
    static func configureDefaults(_ settingsStore: SettingsStore) {
        settingsStore.selectedModel = defaultModelId
    }

    @MainActor
    static func configureDefaults(_ registry: ProviderRegistry, settingsStore: SettingsStore) {
        registry.activeProviderId = defaultProviderId
        registry.activeModelId = defaultModelId
        settingsStore.selectedModel = defaultModelId
    }

    @MainActor
    private static func restoreRealSessionSelection(
        _ restored: (
            messages: [ChatMessage],
            summaryMessageId: UUID?,
            reasoningEffort: ReasoningEffort?,
            providerId: String?,
            modelId: String?
        ),
        registry: ProviderRegistry,
        settingsStore: SettingsStore
    ) {
        if let effort = restored.reasoningEffort {
            settingsStore.reasoningEffort = effort
        }

        if let providerId = restored.providerId, registry.hasAPIKey(for: providerId) {
            registry.activeProviderId = providerId
        } else {
            normalizeRealSessionSelection(registry: registry, settingsStore: settingsStore)
        }

        if let modelId = restored.modelId,
           restored.providerId == registry.activeProviderId,
           registry.modelsDevProviders[registry.activeProviderId]?.models[modelId] != nil {
            registry.activeModelId = modelId
        }

        settingsStore.selectedModel = registry.activeModelId
    }

    @MainActor
    private static func normalizeRealSessionSelection(
        registry: ProviderRegistry,
        settingsStore: SettingsStore
    ) {
        if registry.activeProvider() == nil,
           let fallbackProviderId = registry.configuredProviders.first?.id {
            registry.activeProviderId = fallbackProviderId
        }

        settingsStore.selectedModel = registry.activeModelId
    }

    static func makeAvailableModels() -> [ModelsResponse.ModelInfo] {
        [
            modelInfo(id: defaultModelId, name: "Claude Sonnet 4.6", promptTokens: 200_000, outputTokens: 24_576),
            modelInfo(id: "gpt-4o", name: "GPT-4o", promptTokens: 128_000, outputTokens: 16_384),
            modelInfo(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", promptTokens: 1_000_000, outputTokens: 32_768),
            modelInfo(id: "o3-mini", name: "o3-mini", promptTokens: 200_000, outputTokens: 100_000),
        ]
    }

    private static func modelInfo(
        id: String,
        name: String,
        promptTokens: Int,
        outputTokens: Int
    ) -> ModelsResponse.ModelInfo {
        ModelsResponse.ModelInfo(
            id: id,
            name: name,
            version: nil,
            capabilities: .init(
                limits: .init(
                    maxContextWindowTokens: promptTokens + outputTokens,
                    maxPromptTokens: promptTokens,
                    maxOutputTokens: outputTokens
                )
            )
        )
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
                    Async/await is Swift's structured concurrency model. It makes async code read like straight-line code, with suspension points marked explicitly by `await`.

                    Use it when:
                    - you want simpler control flow than nested callbacks
                    - you want async errors to use `try` / `catch`
                    - you want cancellation and task structure to work naturally
                    """,
                    timestamp: now.addingTimeInterval(-3570),
                    tokenUsage: TokenUsage(promptTokens: 42, completionTokens: 109, totalTokens: 151)
                ),
            ],
            providerId: defaultProviderId,
            modelId: defaultModelId,
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
                    content: "Use `.searchable()` on the `List` or its navigation container. SwiftUI will place the search UI in the right spot for each platform automatically.",
                    timestamp: now.addingTimeInterval(-7180),
                    tokenUsage: TokenUsage(promptTokens: 28, completionTokens: 38, totalTokens: 66)
                ),
            ],
            providerId: defaultProviderId,
            modelId: "gpt-4o",
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
                    content: "This demo shows a mix of coding-friendly models, including Claude Sonnet 4.6, GPT-4o, Gemini 2.5 Pro, and o3-mini.",
                    timestamp: now.addingTimeInterval(-580),
                    tokenUsage: TokenUsage(promptTokens: 22, completionTokens: 31, totalTokens: 53)
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
        Demo mode response from \(model).

        You're using the built-in demo experience because no GitHub login or provider API key is configured yet.

        You asked: \(headline)

        To unlock full functionality, sign in with GitHub or add an API key in Settings.
        """
    }

    static func title(for userMessage: String) -> String {
        let text = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Demo conversation" }
        return text.count > 50 ? String(text.prefix(50)) + "..." : text
    }
}

extension DemoMode {
    static let copilotProviderMetadata = ModelsDevProvider(
        id: defaultProviderId,
        name: "GitHub Copilot",
        env: [],
        npm: "@ai-sdk/openai-compatible",
        api: "https://api.githubcopilot.com",
        doc: "https://github.com/features/copilot",
        models: [
            defaultModelId: ModelsDevModel(
                id: defaultModelId,
                name: "Claude Sonnet 4.6",
                reasoning: true,
                attachment: true,
                toolCall: true,
                structuredOutput: false,
                temperature: true,
                cost: nil,
                limit: ModelsDevLimit(context: 200_000, output: 24_576, input: nil),
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

struct DemoCopilotProvider: LLMProvider {
    let id = DemoMode.defaultProviderId
    let displayName = "GitHub Copilot"

    func streamCompletion(
        messages: [APIMessage],
        model: String,
        tools: [APITool]?,
        options: ProviderOptions
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        let prompt = messages.last(where: { $0.role == "user" })?.content ?? ""
        let response = DemoMode.response(for: prompt, model: model)

        return AsyncThrowingStream { continuation in
            continuation.yield(.thinkingDelta("Demo mode"))
            continuation.yield(.contentDelta(response))
            continuation.yield(.usage(TokenUsage(
                promptTokens: max(24, prompt.count / 4),
                completionTokens: max(48, response.count / 5),
                totalTokens: max(72, prompt.count / 4 + response.count / 5)
            )))
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
        let title = DemoMode.title(for: prompt)
        return ProviderResponse(
            content: title,
            usage: TokenUsage(
                promptTokens: max(12, prompt.count / 4),
                completionTokens: max(6, title.count / 4),
                totalTokens: max(18, prompt.count / 4 + title.count / 4)
            ),
            finishReason: .stop
        )
    }
}
