import Foundation
import Observation

// MARK: - Provider Registry

/// Central hub for managing LLM providers. Routes to the correct provider
/// implementation based on the models.dev `npm` field.
@Observable
@MainActor
final class ProviderRegistry {
    private static let codexModelsEndpoint = "https://chatgpt.com/backend-api/codex/models"
    private static let codexClientVersion = "1.0.0"
    private static let codexUserAgent = "opencode/\(codexClientVersion)"
    private static let codexModelsCacheTTL: TimeInterval = 5 * 60
    private static var codexModelsCache: (models: [CodexCatalogModel], fetchedAt: Date)?

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
                let normalizedRemembered = remembered.map { Self.normalizeModelId($0, providerId: activeProviderId) }
                if let normalizedRemembered,
                   modelsDevProviders[activeProviderId]?.models[normalizedRemembered] != nil {
                    activeModelId = normalizedRemembered
                } else {
                    activeModelId = defaultModelId(for: activeProviderId)
                }
            }
        }
    }

    /// Currently active model ID
    var activeModelId: String {
        didSet {
            let normalized = Self.normalizeModelId(activeModelId, providerId: activeProviderId)
            if normalized != activeModelId {
                activeModelId = normalized
                return
            }
            UserDefaults.standard.set(activeModelId, forKey: "activeModelId")
            UserDefaults.standard.set(activeModelId, forKey: "providerModel-\(activeProviderId)")
        }
    }

    /// Loading state
    var isLoadingProviders = false

    private let authManager: AuthManager

    init(authManager: AuthManager) {
        self.authManager = authManager
        let storedProviderId = UserDefaults.standard.string(forKey: "activeProviderId") ?? "github-copilot"
        self.activeProviderId = storedProviderId
        let storedModel = UserDefaults.standard.string(forKey: "activeModelId") ?? ""
        self.activeModelId = Self.normalizeModelId(storedModel, providerId: storedProviderId)
    }

    // MARK: - Initialization

    func loadProviders() async {
        isLoadingProviders = true
        modelsDevProviders = await ModelsDev.shared.providers()
        modelsDevProviders.merge(Self.hardcodedProviders) { $1 }
        loadConfiguredProviders()
        await refreshCodexModels()
        validateActiveModelSelection()
        isLoadingProviders = false
    }

    func refreshProviders() async {
        isLoadingProviders = true
        var fresh = await ModelsDev.shared.refresh()
        fresh.merge(Self.hardcodedProviders) { $1 }
        modelsDevProviders = fresh
        await refreshCodexModels(force: true)
        validateActiveModelSelection()
        isLoadingProviders = false
    }

    // MARK: - Hardcoded Providers

    /// Provider entries not available from models.dev API.
    private static let hardcodedProviders: [String: ModelsDevProvider] = {
        // Codex OAuth model availability depends on the ChatGPT account entitlement.
        // Keep this conservative until we fetch the live catalog from the backend.
        let codexModels: [String: ModelsDevModel] = [
            "codex-mini-latest": ModelsDevModel(
                id: "codex-mini-latest", name: "Codex Mini",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: false,
                cost: ModelsDevCost(input: 1.5, output: 6, cacheRead: 0.375, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 100_000, input: nil),
                releaseDate: "2025-05-16", status: nil,
                family: "gpt-codex", knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "gpt-5.1-codex": ModelsDevModel(
                id: "gpt-5.1-codex", name: "GPT-5.1 Codex",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: false,
                cost: ModelsDevCost(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: nil),
                limit: ModelsDevLimit(context: 400_000, output: 128_000, input: 272_000),
                releaseDate: "2025-11-13", status: nil,
                family: "gpt-codex", knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "gpt-5.3-codex": ModelsDevModel(
                id: "gpt-5.3-codex", name: "GPT-5.3 Codex",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: false,
                cost: ModelsDevCost(input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: nil),
                limit: ModelsDevLimit(context: 400_000, output: 128_000, input: 272_000),
                releaseDate: "2026-02-05", status: nil,
                family: "gpt-codex", knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
        ]
        let augmentModels: [String: ModelsDevModel] = [
            "claude-haiku-4-5": ModelsDevModel(
                id: "claude-haiku-4-5", name: "Haiku 4.5",
                reasoning: false, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 8_192, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "claude-sonnet-4": ModelsDevModel(
                id: "claude-sonnet-4", name: "Sonnet 4",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "claude-sonnet-4-5": ModelsDevModel(
                id: "claude-sonnet-4-5", name: "Sonnet 4.5",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "claude-sonnet-4-6": ModelsDevModel(
                id: "claude-sonnet-4-6", name: "Sonnet 4.6",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 24_576, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "claude-opus-4-5": ModelsDevModel(
                id: "claude-opus-4-5", name: "Opus 4.5",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "claude-opus-4-6": ModelsDevModel(
                id: "claude-opus-4-6", name: "Opus 4.6",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 24_576, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "gemini-3-1-pro-preview": ModelsDevModel(
                id: "gemini-3-1-pro-preview", name: "Gemini 3.1 Pro",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 65_536, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "gpt-5": ModelsDevModel(
                id: "gpt-5", name: "GPT-5",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "gpt-5-1": ModelsDevModel(
                id: "gpt-5-1", name: "GPT-5.1",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "gpt-5-2": ModelsDevModel(
                id: "gpt-5-2", name: "GPT-5.2",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 200_000, output: 16_384, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
            ),
            "gpt-5-4": ModelsDevModel(
                id: "gpt-5-4", name: "GPT-5.4",
                reasoning: true, attachment: true, toolCall: true, structuredOutput: false, temperature: true,
                cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
                limit: ModelsDevLimit(context: 272_000, output: 32_768, input: nil),
                releaseDate: nil, status: nil,
                family: nil, knowledge: nil, modalities: nil, openWeights: nil, lastUpdated: nil,
                isSubscriptonPlan: false
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

    /// Keychain-backed credentials are the source of truth.
    /// `configuredProviderIds` is still persisted for quick restore, but it can
    /// get stale if a key was synced/imported outside the current session.
    private var detectedConfiguredProviderIds: Set<String> {
        Set(allProvidersSorted.lazy.map(\.id).filter { self.hasAPIKey(for: $0) })
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

        // Special case: OpenAI Codex (OAuth or API key)
        if providerId == "openai-codex" {
            if let codexAuth = PluginRegistry.shared.codexAuth, codexAuth.isAuthenticated {
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
                    toolCall: mdModel.toolCall, structuredOutput: mdModel.structuredOutput,
                    temperature: mdModel.temperature,
                    cost: mdModel.cost, limit: newLimit,
                    releaseDate: mdModel.releaseDate, status: mdModel.status,
                    family: mdModel.family, knowledge: mdModel.knowledge,
                    modalities: mdModel.modalities, openWeights: mdModel.openWeights,
                    lastUpdated: mdModel.lastUpdated,
                    showInPicker: mdModel.showInPicker,
                    priority: mdModel.priority,
                    isSubscriptonPlan: false
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
        let specialIds: Set<String> = ["github-copilot", "openai-codex", "augment"]
        // Always show Copilot first if authenticated
        if authManager.isAuthenticated, let copilot = modelsDevProviders["github-copilot"] {
            result.append(copilot)
        }
        // Show Codex if authenticated (OAuth or API key)
        if (PluginRegistry.shared.codexAuth?.isAuthenticated ?? false) || loadAPIKey(for: "openai-codex") != nil,
           let codex = modelsDevProviders["openai-codex"] {
            result.append(codex)
        }
        // Show Augment if credentials are configured
        if loadAPIKey(for: "augment") != nil, loadAugmentTenantURL() != nil,
           let augment = modelsDevProviders["augment"] {
            result.append(augment)
        }
        // Then every provider that currently resolves to a usable credential.
        for provider in allProvidersSorted where !specialIds.contains(provider.id) {
            if hasAPIKey(for: provider.id) {
                result.append(provider)
            }
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
        if providerId == "openai-codex" { return (PluginRegistry.shared.codexAuth?.isAuthenticated ?? false) || loadAPIKey(for: providerId) != nil }
        if providerId == "augment" { return loadAPIKey(for: providerId) != nil && loadAugmentTenantURL() != nil }
        return loadAPIKey(for: providerId) != nil
    }

    // MARK: - Augment Credentials

    private static let augmentTenantURLKey = "augment-tenant-url"

    private static func normalizeModelId(_ modelId: String, providerId: String) -> String {
        guard providerId == "augment" else { return modelId }

        switch modelId {
        case "haiku4.5":
            return "claude-haiku-4-5"
        case "sonnet4":
            return "claude-sonnet-4"
        case "sonnet4.5":
            return "claude-sonnet-4-5"
        case "sonnet4.6":
            return "claude-sonnet-4-6"
        case "opus4.5":
            return "claude-opus-4-5"
        case "opus4.6":
            return "claude-opus-4-6"
        case "gemini-3.1-pro-preview":
            return "gemini-3-1-pro-preview"
        case "gpt5":
            return "gpt-5"
        case "gpt5.1":
            return "gpt-5-1"
        case "gpt5.2":
            return "gpt-5-2"
        case "gpt5.4":
            return "gpt-5-4"
        default:
            return modelId
        }
    }

    func saveAugmentCredentials(accessToken: String, tenantURL: String) {
        saveAPIKey(accessToken, for: "augment")
        KeychainHelper.save(tenantURL, for: Self.augmentTenantURLKey)
    }

    func loadAugmentTenantURL() -> String? {
        KeychainHelper.loadString(key: Self.augmentTenantURLKey)
    }

    @discardableResult
    func refreshCodexModels(force: Bool = false) async -> Bool {
        guard let auth = PluginRegistry.shared.codexAuth, auth.isAuthenticated else {
            restoreFallbackCodexModels()
            return false
        }

        if !force,
           let cache = Self.codexModelsCache,
           Date().timeIntervalSince(cache.fetchedAt) < Self.codexModelsCacheTTL {
            applyCodexCatalogModels(cache.models)
            return true
        }

        do {
            let token = try await auth.validAccessToken()
            let models = try await fetchCodexCatalogModels(
                token: token,
                accountId: auth.accountId
            )
            guard !models.isEmpty else { return false }
            Self.codexModelsCache = (models: models, fetchedAt: Date())
            applyCodexCatalogModels(models)
            return true
        } catch {
            print("[ProviderRegistry] Codex models refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    func restoreFallbackCodexModels() {
        guard let fallback = Self.hardcodedProviders["openai-codex"] else { return }
        Self.codexModelsCache = nil
        modelsDevProviders["openai-codex"] = fallback
        validateActiveModelSelection()
    }

    // MARK: - Persistence

    private func saveConfiguredProviders() {
        let ids = Array(configuredProviderIds)
        UserDefaults.standard.set(ids, forKey: "configuredProviderIds")
    }

    private func loadConfiguredProviders() {
        let storedIds = Set(UserDefaults.standard.stringArray(forKey: "configuredProviderIds") ?? [])
        var resolvedIds = storedIds.union(detectedConfiguredProviderIds)

        if authManager.isAuthenticated {
            resolvedIds.insert("github-copilot")
        }

        resolvedIds = Set(resolvedIds.filter { hasAPIKey(for: $0) })
        configuredProviderIds = resolvedIds

        if resolvedIds != storedIds {
            saveConfiguredProviders()
        }
    }

    private func validateActiveModelSelection() {
        guard modelsDevProviders[activeProviderId] != nil else { return }

        let normalized = Self.normalizeModelId(activeModelId, providerId: activeProviderId)
        if normalized != activeModelId {
            activeModelId = normalized
            return
        }

        guard modelsDevProviders[activeProviderId]?.models[activeModelId] == nil else { return }
        activeModelId = defaultModelId(for: activeProviderId)
    }

    private func defaultModelId(for providerId: String) -> String {
        let allModels = modelsDevProviders[providerId].map { Array($0.models.values) } ?? []
        let visibleModels = allModels.filter(\.showInPicker)
        let candidates = visibleModels.isEmpty ? allModels : visibleModels

        return candidates.sorted { a, b in
            if (a.priority ?? Int.max) != (b.priority ?? Int.max) {
                return (a.priority ?? Int.max) < (b.priority ?? Int.max)
            }
            if a.limit.context != b.limit.context {
                return a.limit.context > b.limit.context
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.first?.id ?? ""
    }

    private func fetchCodexCatalogModels(
        token: String,
        accountId: String?
    ) async throws -> [CodexCatalogModel] {
        guard var components = URLComponents(string: Self.codexModelsEndpoint) else {
            throw ProviderError.invalidResponse(statusCode: 0, body: "Invalid Codex models URL")
        }
        components.queryItems = [
            URLQueryItem(name: "client_version", value: Self.codexClientVersion)
        ]

        guard let url = components.url else {
            throw ProviderError.invalidResponse(statusCode: 0, body: "Invalid Codex models URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.codexUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("opencode", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.invalidResponse(statusCode: code, body: body)
        }

        let decoded = try JSONDecoder().decode(CodexCatalogResponse.self, from: data)
        return decoded.models
    }

    private func applyCodexCatalogModels(_ remoteModels: [CodexCatalogModel]) {
        guard let existing = modelsDevProviders["openai-codex"] else { return }

        let mapped = Dictionary(uniqueKeysWithValues: remoteModels.map { model in
            (model.slug, model.toModelsDevModel())
        })
        guard !mapped.isEmpty else { return }

        modelsDevProviders["openai-codex"] = ModelsDevProvider(
            id: existing.id,
            name: existing.name,
            env: existing.env,
            npm: existing.npm,
            api: existing.api,
            doc: existing.doc,
            models: mapped
        )
        validateActiveModelSelection()
    }
}

private struct CodexCatalogResponse: Decodable {
    let models: [CodexCatalogModel]
}

private struct CodexCatalogModel: Decodable {
    enum Visibility: String, Decodable {
        case list
        case hide
    }

    struct ReasoningPreset: Decodable {
        let effort: String
    }

    let slug: String
    let displayName: String
    let description: String?
    let defaultReasoningLevel: String?
    let supportedReasoningLevels: [ReasoningPreset]
    let visibility: Visibility
    let supportedInAPI: Bool
    let priority: Int?
    let contextWindow: Int?
    let inputModalities: [String]

    enum CodingKeys: String, CodingKey {
        case slug, description, visibility, priority
        case displayName = "display_name"
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningLevels = "supported_reasoning_levels"
        case supportedInAPI = "supported_in_api"
        case contextWindow = "context_window"
        case inputModalities = "input_modalities"
    }

    func toModelsDevModel() -> ModelsDevModel {
        let context = contextWindow ?? 272_000
        let output = min(32_000, max(context / 8, 8_192))
        let input = max(context - output, 0)
        let name = Self.displayName(displayName: displayName, slug: slug)
        let family = slug.contains("codex") ? "gpt-codex" : "gpt-5"
        let modalities = inputModalities.isEmpty ? nil : ModelsDevModalities(input: inputModalities, output: nil)
        let supportsReasoning = defaultReasoningLevel != nil || !supportedReasoningLevels.isEmpty

        return ModelsDevModel(
            id: slug,
            name: name,
            reasoning: supportsReasoning,
            attachment: true,
            toolCall: true,
            structuredOutput: false,
            temperature: false,
            cost: ModelsDevCost(input: -1, output: -1, cacheRead: nil, cacheWrite: nil),
            limit: ModelsDevLimit(context: context, output: output, input: input),
            releaseDate: nil,
            status: supportedInAPI ? nil : "chatgpt-only",
            family: family,
            knowledge: nil,
            modalities: modalities,
            openWeights: nil,
            lastUpdated: nil,
            showInPicker: visibility == .list,
            priority: priority,
            isSubscriptonPlan: false
        )
    }

    private static func displayName(displayName: String, slug: String) -> String {
        guard displayName == slug else { return displayName }

        return slug
            .replacingOccurrences(of: "gpt", with: "GPT")
            .replacingOccurrences(of: "oss", with: "OSS")
            .replacingOccurrences(of: "codex", with: "Codex")
            .replacingOccurrences(of: "mini", with: "Mini")
            .replacingOccurrences(of: "max", with: "Max")
    }
}
