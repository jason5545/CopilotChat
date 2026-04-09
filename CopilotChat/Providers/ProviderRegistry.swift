import Foundation
import Observation

// MARK: - Provider Registry

/// Central hub for managing LLM providers. Routes to the correct provider
/// implementation based on the models.dev `npm` field.
@Observable
@MainActor
final class ProviderRegistry {
    /// All provider data from models.dev
    var modelsDevProviders: [String: ModelsDevProvider] = [:]

    /// User-configured providers (have API keys)
    var configuredProviderIds: Set<String> = []

    /// Currently active provider ID
    var activeProviderId: String {
        didSet {
            UserDefaults.standard.set(activeProviderId, forKey: "activeProviderId")
            // Reset model when provider changes — pick first available or clear
            if oldValue != activeProviderId {
                let firstModel = modelsDevProviders[activeProviderId]?.models.values
                    .max { a, b in
                        a.limit.context != b.limit.context
                            ? a.limit.context < b.limit.context
                            : a.name > b.name
                    }?.id ?? ""
                activeModelId = firstModel
            }
        }
    }

    /// Currently active model ID
    var activeModelId: String {
        didSet { UserDefaults.standard.set(activeModelId, forKey: "activeModelId") }
    }

    /// Loading state
    var isLoadingProviders = false

    private let authManager: AuthManager

    init(authManager: AuthManager) {
        self.authManager = authManager
        self.activeProviderId = UserDefaults.standard.string(forKey: "activeProviderId") ?? "github-copilot"
        self.activeModelId = UserDefaults.standard.string(forKey: "activeModelId") ?? ""
    }

    // MARK: - Initialization

    func loadProviders() async {
        isLoadingProviders = true
        modelsDevProviders = await ModelsDev.shared.providers()
        loadConfiguredProviders()
        isLoadingProviders = false
    }

    func refreshProviders() async {
        isLoadingProviders = true
        modelsDevProviders = await ModelsDev.shared.refresh()
        isLoadingProviders = false
    }

    // MARK: - Provider Resolution

    /// Get the active LLM provider instance.
    func activeProvider() -> (any LLMProvider)? {
        provider(for: activeProviderId)
    }

    /// Get a provider instance by ID.
    func provider(for providerId: String) -> (any LLMProvider)? {
        // Special case: GitHub Copilot
        if providerId == "github-copilot" {
            guard authManager.isAuthenticated else { return nil }
            return CopilotProvider(tokenProvider: { [weak authManager] in
                await MainActor.run { authManager?.token }
            })
        }

        // Special case: OpenAI Codex (OAuth)
        if providerId == "openai-codex" {
            // TODO: Wire OpenAICodexAuth instance
            return nil
        }

        // models.dev providers
        guard let mdProvider = modelsDevProviders[providerId] else { return nil }
        guard let apiKey = loadAPIKey(for: providerId) else { return nil }

        // Route based on npm field (API format)
        switch mdProvider.apiFormat {
        case .anthropicCompatible:
            return AnthropicCompatibleProvider(provider: mdProvider, apiKey: apiKey)
        case .gemini:
            return GeminiProvider(provider: mdProvider, apiKey: apiKey)
        case .openaiCompatible:
            return OpenAICompatibleProvider(provider: mdProvider, apiKey: apiKey)
        case .copilot:
            return CopilotProvider(tokenProvider: { [weak authManager] in
                await MainActor.run { authManager?.token }
            })
        case .openaiCodex:
            return nil
        }
    }

    // MARK: - Copilot Limits Overlay

    /// Overlay Copilot API's actual limits onto the models.dev data for github-copilot.
    func overlayCopilotLimits(from copilotModels: [ModelsResponse.ModelInfo]) {
        guard let copilotProvider = modelsDevProviders["github-copilot"] else { return }
        var updated = copilotProvider.models
        for apiModel in copilotModels {
            guard let mdModel = updated[apiModel.id] else { continue }
            let prompt = apiModel.capabilities?.limits?.maxPromptTokens
            let output = apiModel.capabilities?.limits?.maxOutputTokens
            if let prompt, let output {
                let newLimit = ModelsDevLimit(context: prompt + output, output: output, input: prompt)
                updated[apiModel.id] = ModelsDevModel(
                    id: mdModel.id, name: mdModel.name,
                    reasoning: mdModel.reasoning, attachment: mdModel.attachment,
                    toolCall: mdModel.toolCall, temperature: mdModel.temperature,
                    cost: mdModel.cost, limit: newLimit,
                    releaseDate: mdModel.releaseDate, status: mdModel.status
                )
            }
        }
        modelsDevProviders["github-copilot"] = ModelsDevProvider(
            id: copilotProvider.id, name: copilotProvider.name,
            env: copilotProvider.env, npm: copilotProvider.npm,
            api: copilotProvider.api, doc: copilotProvider.doc,
            models: updated
        )
    }

    // MARK: - Models

    /// Get available models for the active provider.
    func activeModels() async -> [ModelsDevModel] {
        if activeProviderId == "github-copilot" {
            // Copilot models come from the API, also available in models.dev
            return await ModelsDev.shared.models(for: "github-copilot")
        }
        return await ModelsDev.shared.models(for: activeProviderId)
    }

    /// Get the ModelsDevModel for the active model. Direct dict lookup — no sorting.
    func activeModelInfo() -> ModelsDevModel? {
        modelsDevProviders[activeProviderId]?.models[activeModelId]
    }

    // MARK: - Available Providers (grouped)

    /// Providers the user has configured (has API key).
    var configuredProviders: [ModelsDevProvider] {
        var result: [ModelsDevProvider] = []
        // Always show Copilot first if authenticated
        if authManager.isAuthenticated, let copilot = modelsDevProviders["github-copilot"] {
            result.append(copilot)
        }
        // Then configured providers
        for id in configuredProviderIds.sorted() {
            if id == "github-copilot" { continue }
            if let p = modelsDevProviders[id] { result.append(p) }
        }
        return result
    }

    /// All providers from models.dev, grouped by popularity/relevance.
    var allProvidersSorted: [ModelsDevProvider] {
        let popular = ["anthropic", "openai", "google", "github-copilot",
                       "zai", "zai-coding-plan", "minimax", "minimax-coding-plan",
                       "minimax-cn", "minimax-cn-coding-plan",
                       "zhipuai", "zhipuai-coding-plan",
                       "alibaba-coding-plan", "alibaba-coding-plan-cn",
                       "tencent-coding-plan",
                       "openrouter", "groq", "xai", "deepseek",
                       "opencode", "opencode-go"]

        var result: [ModelsDevProvider] = []
        // Popular providers first
        for id in popular {
            if let p = modelsDevProviders[id] { result.append(p) }
        }
        // Then the rest sorted by name
        let popularSet = Set(popular)
        let remaining = modelsDevProviders.values
            .filter { !popularSet.contains($0.id) }
            .sorted { $0.name < $1.name }
        result.append(contentsOf: remaining)
        return result
    }

    // MARK: - API Key Management

    private static func keychainKey(for providerId: String) -> String {
        "provider-apikey-\(providerId)"
    }

    func saveAPIKey(_ key: String, for providerId: String) {
        KeychainHelper.save(key, for: Self.keychainKey(for: providerId))
        configuredProviderIds.insert(providerId)
        saveConfiguredProviders()
    }

    func loadAPIKey(for providerId: String) -> String? {
        KeychainHelper.loadString(key: Self.keychainKey(for: providerId))
    }

    func removeAPIKey(for providerId: String) {
        KeychainHelper.delete(key: Self.keychainKey(for: providerId))
        configuredProviderIds.remove(providerId)
        saveConfiguredProviders()
    }

    func hasAPIKey(for providerId: String) -> Bool {
        if providerId == "github-copilot" { return authManager.isAuthenticated }
        return loadAPIKey(for: providerId) != nil
    }

    // MARK: - Persistence

    private func saveConfiguredProviders() {
        let ids = Array(configuredProviderIds)
        UserDefaults.standard.set(ids, forKey: "configuredProviderIds")
    }

    private func loadConfiguredProviders() {
        let ids = UserDefaults.standard.stringArray(forKey: "configuredProviderIds") ?? []
        configuredProviderIds = Set(ids)
        // Also check Copilot
        if authManager.isAuthenticated {
            configuredProviderIds.insert("github-copilot")
        }
    }
}
