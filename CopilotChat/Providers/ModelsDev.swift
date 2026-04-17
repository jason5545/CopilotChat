import Foundation

// MARK: - Models.dev API Integration

/// Fetches and caches provider/model metadata from https://models.dev/api.json
/// This gives access to 120+ providers and 2000+ models dynamically.
actor ModelsDev {
    static let shared = ModelsDev()

    private let apiURL = URL(string: "https://models.dev/api.json")!
    private let cacheTTL: TimeInterval = 5 * 60 // 5 minutes
    private var cachedData: [String: ModelsDevProvider]?
    private var lastFetchTime: Date?

    private var cacheFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models-dev-cache.json")
    }

    // MARK: - Public API

    func providers() async -> [String: ModelsDevProvider] {
        if let cached = cachedData, let lastFetch = lastFetchTime,
           Date().timeIntervalSince(lastFetch) < cacheTTL {
            return cached
        }
        return await refresh()
    }

    func provider(id: String) async -> ModelsDevProvider? {
        let all = await providers()
        return all[id]
    }

    func models(for providerId: String) async -> [ModelsDevModel] {
        guard let provider = await provider(id: providerId) else { return [] }
        return provider.sortedModels
    }

    @discardableResult
    func refresh() async -> [String: ModelsDevProvider] {
        // Try network first
        if let fetched = await fetchFromNetwork() {
            cachedData = fetched
            lastFetchTime = Date()
            await saveToDisk(fetched)
            return fetched
        }
        // Fall back to disk cache
        if let diskData = loadFromDisk() {
            cachedData = diskData
            lastFetchTime = Date()
            return diskData
        }
        return [:]
    }

    // MARK: - Network

    private func fetchFromNetwork() async -> [String: ModelsDevProvider]? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("CopilotChat/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            let raw = try JSONDecoder().decode([String: ModelsDevRawProvider].self, from: data)
            return raw.mapValues { $0.toProvider() }
        } catch {
            print("[ModelsDev] Fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Disk Cache

    private func saveToDisk(_ data: [String: ModelsDevProvider]) async {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: cacheFileURL)
        } catch {
            print("[ModelsDev] Cache save error: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() -> [String: ModelsDevProvider]? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
    }
}

// MARK: - Data Models

struct ModelsDevProvider: Codable, Sendable, Identifiable, Hashable {
    static func == (lhs: ModelsDevProvider, rhs: ModelsDevProvider) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: String
    let name: String
    let env: [String]
    let npm: String?
    let api: String?
    let doc: String?
    let models: [String: ModelsDevModel]

    var apiFormat: ProviderAPIFormat {
        .from(npm: npm)
    }

    var sortedModels: [ModelsDevModel] {
        let visible = models.values.filter(\.showInPicker)
        let source = visible.isEmpty ? Array(models.values) : visible
        return source.sorted { a, b in
            if (a.priority ?? Int.max) != (b.priority ?? Int.max) {
                return (a.priority ?? Int.max) < (b.priority ?? Int.max)
            }
            if a.limit.context != b.limit.context {
                return a.limit.context > b.limit.context
            }
            return a.name < b.name
        }
    }

    var requiresAPIKey: Bool { !env.isEmpty }
    var isCodingPlan: Bool { id.contains("coding-plan") }
    var isAPIBased: Bool { npm == nil || npm?.isEmpty == true }
    var isChinaRegion: Bool { id.contains("-cn") }
}

struct ModelsDevModel: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let reasoning: Bool
    let attachment: Bool
    let toolCall: Bool
    let structuredOutput: Bool
    let temperature: Bool
    let cost: ModelsDevCost?
    let limit: ModelsDevLimit
    let releaseDate: String?
    let status: String?
    let family: String?
    let knowledge: String?
    let modalities: ModelsDevModalities?
    let openWeights: Bool?
    let lastUpdated: String?
    var showInPicker: Bool = true
    var priority: Int? = nil
    let isSubscriptonPlan: Bool

    var contextWindow: Int { limit.context }
    var maxOutputTokens: Int { limit.output }
    var isFree: Bool { cost == nil || (cost?.input == 0 && cost?.output == 0) }
    var isVision: Bool { modalities?.input?.contains("image") ?? false }

    var displayContextWindow: String {
        let tokens = limit.context
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }

    var displayCost: String {
        if isSubscriptonPlan { return "Plan" }
        guard let cost, !isFree else { return "Free" }
        if cost.input < 0 || cost.output < 0 { return "Subscription" }
        return "$\(String(format: "%.2f", cost.input))/$\(String(format: "%.2f", cost.output)) per 1M"
    }
}

struct ModelsDevCost: Codable, Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}

struct ModelsDevModalities: Codable, Sendable {
    let input: [String]?
    let output: [String]?
}

struct ModelsDevLimit: Codable, Sendable {
    let context: Int
    let output: Int
    let input: Int?
}

extension ModelsDevModel {
    enum CodingKeys: String, CodingKey {
        case id, name, reasoning, attachment, temperature, cost, limit, status
        case toolCall = "toolCall"
        case structuredOutput = "structuredOutput"
        case releaseDate = "releaseDate"
        case family, knowledge, modalities
        case openWeights = "openWeights"
        case lastUpdated = "lastUpdated"
        case showInPicker
        case priority
        case isSubscriptonPlan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        reasoning = try container.decode(Bool.self, forKey: .reasoning)
        attachment = try container.decode(Bool.self, forKey: .attachment)
        toolCall = try container.decode(Bool.self, forKey: .toolCall)
        structuredOutput = try container.decode(Bool.self, forKey: .structuredOutput)
        temperature = try container.decode(Bool.self, forKey: .temperature)
        cost = try container.decodeIfPresent(ModelsDevCost.self, forKey: .cost)
        limit = try container.decode(ModelsDevLimit.self, forKey: .limit)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        family = try container.decodeIfPresent(String.self, forKey: .family)
        knowledge = try container.decodeIfPresent(String.self, forKey: .knowledge)
        modalities = try container.decodeIfPresent(ModelsDevModalities.self, forKey: .modalities)
        openWeights = try container.decodeIfPresent(Bool.self, forKey: .openWeights)
        lastUpdated = try container.decodeIfPresent(String.self, forKey: .lastUpdated)
        showInPicker = try container.decodeIfPresent(Bool.self, forKey: .showInPicker) ?? true
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        isSubscriptonPlan = try container.decode(Bool.self, forKey: .isSubscriptonPlan)
    }
}

// MARK: - Raw API Response (for decoding)

private struct ModelsDevRawProvider: Codable {
    let id: String?
    let name: String
    let env: [String]
    let npm: String?
    let api: String?
    let doc: String?
    let models: [String: ModelsDevRawModel]

    func toProvider() -> ModelsDevProvider {
        let providerIsSubscriptionPlan = (id ?? "").contains("-coding-plan")
        let convertedModels = models.compactMapValues { raw -> ModelsDevModel? in
            return raw.toModel(providerIsSubscriptionPlan: providerIsSubscriptionPlan)
        }
        return ModelsDevProvider(
            id: id ?? "",
            name: name,
            env: env,
            npm: npm,
            api: api,
            doc: doc,
            models: convertedModels
        )
    }
}

private struct ModelsDevRawModel: Codable {
    let id: String
    let name: String
    let reasoning: Bool?
    let attachment: Bool?
    let toolCall: Bool?
    let structuredOutput: Bool?
    let temperature: Bool?
    let cost: ModelsDevCost?
    let limit: ModelsDevRawLimit?
    let releaseDate: String?
    let status: String?
    let family: String?
    let knowledge: String?
    let modalities: ModelsDevModalities?
    let openWeights: Bool?
    let lastUpdated: String?

    struct ModelsDevRawLimit: Codable {
        let context: Int?
        let output: Int?
        let input: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id, name, reasoning, attachment, temperature, cost, limit, status
        case toolCall = "tool_call"
        case structuredOutput = "structured_output"
        case releaseDate = "release_date"
        case family, knowledge, modalities
        case openWeights = "open_weights"
        case lastUpdated = "last_updated"
    }

    func toModel(providerIsSubscriptionPlan: Bool) -> ModelsDevModel? {
        let ctx = limit?.context ?? 0
        let out = limit?.output ?? 4096
        guard ctx > 0 else { return nil }

        return ModelsDevModel(
            id: id,
            name: name,
            reasoning: reasoning ?? false,
            attachment: attachment ?? false,
            toolCall: toolCall ?? false,
            structuredOutput: structuredOutput ?? false,
            temperature: temperature ?? true,
            cost: cost,
            limit: ModelsDevLimit(context: ctx, output: out, input: limit?.input),
            releaseDate: releaseDate,
            status: status,
            family: family,
            knowledge: knowledge,
            modalities: modalities,
            openWeights: openWeights,
            lastUpdated: lastUpdated,
            showInPicker: true,
            priority: nil,
            isSubscriptonPlan: providerIsSubscriptionPlan
        )
    }
}
