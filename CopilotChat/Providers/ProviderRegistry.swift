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
            if oldValue != activeProviderId {
                let remembered = UserDefaults.standard.string(forKey: "providerModel-\(activeProviderId)")
                if let remembered, modelsDevProviders[activeProviderId]?.models[remembered] != nil {
                    activeModelId = remembered
                } else {
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
    }

    /// Currently active model ID
    var activeModelId: String {
        didSet {
            UserDefaults.standard.set(activeModelId, forKey: "activeModelId")
            UserDefaults.standard.set(activeModelId, forKey: "providerModel-\(activeProviderId)")
        }
    }

    /// Loading state
    var isLoadingProviders = false

    /// OpenAI Codex OAuth
    let codexAuth = OpenAICodexAuth()

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
        modelsDevProviders.merge(Self.hardcodedProviders) { $1 }
        loadConfiguredProviders()
        isLoadingProviders = false
    }

    func refreshProviders() async {
        isLoadingProviders = true
        var fresh = await ModelsDev.shared.refresh()
        fresh.merge(Self.hardcodedProviders) { $1 }
        modelsDevProviders = fresh
        isLoadingProviders = false
    }

    // MARK: - Hardcoded Providers

    /// Provider entries not available from models.dev API.
    private static let hardcodedProviders: [String: ModelsDevProvider] = {
        let codexModels: [String: ModelsDevModel] = [
            "codex-mini-latest": ModelsDevModel(
                id: "codex-mini-latest", name: "Codex Mini",
                reasoning: true, attachment: true, toolCall: true, temperature: false,
                cost: ModelsDevCost(input: 1.5, output: 6, cacheRead: 0.375, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 100_000, input: nil),
                releaseDate: "2025-05-16", status: nil
            ),
            "gpt-5.1-codex": ModelsDevModel(
                id: "gpt-5.1-codex", name: "GPT-5.1 Codex",
                reasoning: true, attachment: true, toolCall: true, temperature: false,
                cost: ModelsDevCost(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: nil),
                limit: ModelsDevLimit(context: 400_000, output: 128_000, input: 272_000),
                releaseDate: "2025-11-13", status: nil
            ),
            "gpt-5.3-codex": ModelsDevModel(
                id: "gpt-5.3-codex", name: "GPT-5.3 Codex",
                reasoning: true, attachment: true, toolCall: true, temperature: false,
                cost: ModelsDevCost(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: nil),
                limit: ModelsDevLimit(context: 400_000, output: 128_000, input: 272_000),
                releaseDate: "2026-02-05", status: nil
            ),
            "gpt-5.3-codex-spark": ModelsDevModel(
                id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark",
                reasoning: true, attachment: true, toolCall: true, temperature: false,
                cost: ModelsDevCost(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: nil),
                limit: ModelsDevLimit(context: 128_000, output: 32_000, input: 100_000),
                releaseDate: "2026-02-05", status: nil
            ),
        ]
        let augmentModels: [String: ModelsDevModel] = [
            "haiku4.5": ModelsDevModel(
                id: "haiku4.5", name: "Haiku 4.5",
                reasoning: false, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 8_192, input: nil),
                releaseDate: nil, status: nil
            ),
            "sonnet4": ModelsDevModel(
                id: "sonnet4", name: "Sonnet 4",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil
            ),
            "sonnet4.5": ModelsDevModel(
                id: "sonnet4.5", name: "Sonnet 4.5",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil
            ),
            "sonnet4.6": ModelsDevModel(
                id: "sonnet4.6", name: "Sonnet 4.6",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil
            ),
            "opus4.5": ModelsDevModel(
                id: "opus4.5", name: "Opus 4.5",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 32_768, input: nil),
                releaseDate: nil, status: nil
            ),
            "opus4.6": ModelsDevModel(
                id: "opus4.6", name: "Opus 4.6",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 32_768, input: nil),
                releaseDate: nil, status: nil
            ),
            "gemini-3.1-pro-preview": ModelsDevModel(
                id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 2_000_000, output: 65_536, input: nil),
                releaseDate: nil, status: nil
            ),
            "gpt5": ModelsDevModel(
                id: "gpt5", name: "GPT-5",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil
            ),
            "gpt5.1": ModelsDevModel(
                id: "gpt5.1", name: "GPT-5.1",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 400_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil
            ),
            "gpt5.2": ModelsDevModel(
                id: "gpt5.2", name: "GPT-5.2",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 400_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil
            ),
            "gpt5.4": ModelsDevModel(
                id: "gpt5.4", name: "GPT-5.4",
                reasoning: true, attachment: true, toolCall: true, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 400_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil
            ),
        ]
        return [
            "openai-codex": ModelsDevProvider(
                id: "openai-codex", name: "OpenAI Codex",
                env: [], npm: nil,
                api: "https://chatgpt.com/backend-api/codex",
                doc: "https://openai.com/codex",
                models: codexModels
            ),
            "augment": ModelsDevProvider(
                id: "augment", name: "Augment Code",
                env: ["AUGMENT_SESSION_AUTH"], npm: nil,
                api: nil,
                doc: "https://docs.augmentcode.com",
                models: augmentModels
            ),
        ]
    }()

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

        // Special case: OpenAI Codex (OAuth or API key)
        if providerId == "openai-codex" {
            if codexAuth.isAuthenticated {
                return OpenAICodexProvider(auth: codexAuth)
            }
            if let mdProvider = modelsDevProviders[providerId],
               let apiKey = loadAPIKey(for: providerId) {
                return OpenAICompatibleProvider(provider: mdProvider, apiKey: apiKey)
            }
            return nil
        }

        // Special case: Augment Code (tenant URL + access token)
        if providerId == "augment" {
            guard let apiKey = loadAPIKey(for: "augment"),
                  let tenantURL = loadAugmentTenantURL() else { return nil }
            return AugmentProvider(baseURL: tenantURL, apiKey: apiKey)
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
        // Show Codex if authenticated (OAuth or API key)
        if codexAuth.isAuthenticated || loadAPIKey(for: "openai-codex") != nil,
           let codex = modelsDevProviders["openai-codex"] {
            result.append(codex)
        }
        // Show Augment if credentials are configured
        if loadAPIKey(for: "augment") != nil, loadAugmentTenantURL() != nil,
           let augment = modelsDevProviders["augment"] {
            result.append(augment)
        }
        // Then configured providers
        for id in configuredProviderIds.sorted() {
            if id == "github-copilot" || id == "openai-codex" || id == "augment" { continue }
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
                       "augment",
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
        if providerId == "augment" {
            KeychainHelper.delete(key: Self.augmentTenantURLKey)
        }
        configuredProviderIds.remove(providerId)
        saveConfiguredProviders()
    }

    func hasAPIKey(for providerId: String) -> Bool {
        if providerId == "github-copilot" { return authManager.isAuthenticated }
        if providerId == "openai-codex" { return codexAuth.isAuthenticated || loadAPIKey(for: providerId) != nil }
        if providerId == "augment" { return loadAPIKey(for: providerId) != nil && loadAugmentTenantURL() != nil }
        return loadAPIKey(for: providerId) != nil
    }

    // MARK: - Augment Credentials

    private static let augmentTenantURLKey = "augment-tenant-url"

    func saveAugmentCredentials(accessToken: String, tenantURL: String) {
        saveAPIKey(accessToken, for: "augment")
        KeychainHelper.save(tenantURL, for: Self.augmentTenantURLKey)
    }

    func loadAugmentTenantURL() -> String? {
        KeychainHelper.loadString(key: Self.augmentTenantURLKey)
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
